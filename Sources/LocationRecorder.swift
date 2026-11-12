import Foundation
import CoreLocation
import Combine

// LocationManager はユーザーが明示的に記録開始した場合のみ継続GPSを有効にします。
// iOSはAndroidのGPS_PROVIDER相当を強制できないため、鮮度・精度で判定します。
@MainActor
final class LocationRecorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var recording = false
    @Published private(set) var status = "停止中"
    @Published private(set) var currentLocation: CLLocation?
    @Published private(set) var speedKmh: Double?
    @Published private(set) var isWithinExcludedZone = false
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var headingDegrees: Double?
    @Published private(set) var currentStayStart: Date?
    private var headingEnabled = false

    var onDataChanged: (() -> Void)?
    private let manager = CLLocationManager()
    private let store: TrackStore
    private var pendingStart = false
    private var pendingOneShot = false
    private var anchor: CLLocation?
    private var anchorTime: Date?
    private var dwellStartedAt: Date?
    private var lastSavedAtSession: Date?
    private var lastGoodFix: Date?
    private var gapPending = false
    private var zoneVisit: (zone: PrivacyZone, entered: Date, lastSeen: Date)?
    private var zonesCache: [PrivacyZone] = []

    init(store: TrackStore) {
        self.store = store
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .fitness
        manager.pausesLocationUpdatesAutomatically = false
        manager.headingFilter = 2
    }

    func start() {
        guard !recording else { return }
        pendingStart = true
        switch manager.authorizationStatus {
        case .notDetermined:
            status = "位置情報の許可待ち"
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            status = "設定から位置情報を許可してください"
            pendingStart = false
        case .authorizedWhenInUse, .authorizedAlways:
            beginRecording()
        @unknown default:
            pendingStart = false
        }
    }

    private func beginRecording() {
        guard pendingStart, !recording else { return }
        pendingStart = false
        do { zonesCache = try store.zones() }
        catch { status = "除外エリア取得失敗: \(error.localizedDescription)"; return }
        anchor = nil; anchorTime = nil; dwellStartedAt = nil; currentStayStart = nil; lastSavedAtSession = nil
        lastGoodFix = nil; gapPending = false; zoneVisit = nil
        isWithinExcludedZone = false
        recording = true
        RDLog.write("GPS recording started")
        status = "GPS測位待ち（新しい測位まで記録なし）"
        // plist UIBackgroundModes=location がある状態でのみtrueにできます。
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        if manager.authorizationStatus == .authorizedWhenInUse {
            // 「常に許可」は利用者が選択します。許可されなくても開始中の継続GPSは試行します。
            manager.requestAlwaysAuthorization()
        }
        onDataChanged?()
    }

    func stop() {
        pendingStart = false
        guard recording else { return }
        closeVisit()
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        recording = false
        RDLog.write("GPS recording stopped")
        status = "停止中"
        isWithinExcludedZone = false
        anchor = nil; anchorTime = nil; dwellStartedAt = nil
        lastSavedAtSession = nil; lastGoodFix = nil; gapPending = false
        onDataChanged?()
    }

    func refreshZones() {
        do { zonesCache = try store.zones() }
        catch { status = "除外エリア読み込み失敗: \(error.localizedDescription)" }
    }

    func requestOneShotLocation() {
        pendingOneShot = true
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: status = "位置情報の許可が必要です"; pendingOneShot = false
        case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
        @unknown default: pendingOneShot = false
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            if pendingStart { beginRecording() }
            if pendingOneShot { manager.requestLocation() }
        } else if manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted {
            pendingStart = false; pendingOneShot = false
            if recording { stop() }
            status = "位置情報の権限がありません"
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if recording { status = "GPS取得エラー（再測位待ち）"; RDLog.write("GPS error code=\((error as NSError).code)") }
        else { status = "現在地を取得できません: \(error.localizedDescription)" }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for fix in locations {
            guard fix.coordinate.latitude.isFinite, fix.coordinate.longitude.isFinite,
                  (-90...90).contains(fix.coordinate.latitude), (-180...180).contains(fix.coordinate.longitude),
                  fix.horizontalAccuracy > 0, fix.horizontalAccuracy <= 35,
                  abs(fix.timestamp.timeIntervalSinceNow) <= 15 else { continue }
            currentLocation = fix
            speedKmh = fix.speed >= 0 && fix.speed.isFinite ? fix.speed * 3.6 : nil
            if recording { process(fix) }
        }
        pendingOneShot = false
    }

    func setCompassEnabled(_ enabled: Bool) {
        headingEnabled = enabled
        if enabled && CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        else { manager.stopUpdatingHeading(); headingDegrees = nil }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        guard headingEnabled, heading.headingAccuracy >= 0 else { return }
        let degrees = heading.trueHeading >= 0 ? heading.trueHeading : heading.magneticHeading
        if degrees.isFinite { headingDegrees = degrees }
    }

    private func process(_ fix: CLLocation) {
        if let lastGoodFix, fix.timestamp <= lastGoodFix { return }
        let now = fix.timestamp
        let interrupted = lastGoodFix.map { now.timeIntervalSince($0) > 45 } ?? false
        if interrupted {
            // GPS欠損中の移動距離・滞在時間は推定しません。
            closeVisit()
            gapPending = anchor != nil
            dwellStartedAt = now; currentStayStart = nil
            status = "GPS途切れ後に復帰（欠損区間を除外）"
        }
        lastGoodFix = now

        let currentZone = zonesCache.first { zone in
            let center = CLLocation(latitude: zone.latitude, longitude: zone.longitude)
            return center.distance(from: fix) <= zone.radius + fix.horizontalAccuracy
        }
        if let zone = currentZone {
            if let visit = zoneVisit, visit.zone.id == zone.id {
                zoneVisit = (zone: zone, entered: visit.entered, lastSeen: now)
            } else {
                closeVisit()
                zoneVisit = (zone: zone, entered: now, lastSeen: now)
            }
            isWithinExcludedZone = true
            // 除外エリア内のGPS点は保存しません。
            if let visit = zoneVisit, now.timeIntervalSince(visit.entered) >= stayThreshold {
                saveQuietly { try store.updateZoneVisit(zoneID: zone.id, title: zone.title, start: visit.entered, end: now) }
            }
            gapPending = anchor != nil
            dwellStartedAt = now; currentStayStart = nil
            status = "記録除外エリア内: \(zone.title)"
            return
        }

        let justExited = zoneVisit != nil
        if justExited {
            closeVisit(); gapPending = anchor != nil; dwellStartedAt = now; currentStayStart = nil
        }
        isWithinExcludedZone = false
        let trustworthySpeed: Double? = {
            guard fix.speed.isFinite, fix.speed >= 0, fix.speed <= 120 else { return nil }
            if fix.speedAccuracy >= 0 && fix.speedAccuracy > 5 { return nil }
            return fix.speed
        }()
        if let speed = trustworthySpeed, speed >= 1 {
            saveQuietly { try store.updateDailyMax(time: now, speed: speed) }
        }
        let peak = (try? store.dailyMax(on: now))?.metersPerSecond

        guard let previous = anchor, let saved = lastSavedAtSession else {
            savePoint(fix, segment: 0, speed: trustworthySpeed, peak: peak, gap: false)
            dwellStartedAt = now; currentStayStart = nil
            return
        }
        let displacement = previous.distance(from: fix)
        let interval = now.timeIntervalSince(saved)
        if !gapPending && !justExited && displacement < distanceThreshold {
            if dwellStartedAt == nil { dwellStartedAt = now }
            currentStayStart = dwellStartedAt
            if let dwellStartedAt, now.timeIntervalSince(dwellStartedAt) >= stayThreshold,
               let anchorTime {
                saveQuietly { try store.updateStay(anchor: anchorTime, start: dwellStartedAt, end: now,
                    latitude: previous.coordinate.latitude, longitude: previous.coordinate.longitude) }
            }
            status = "記録中（移動なし）"
            return
        }
        if !gapPending && !justExited && interval < intervalThreshold { return }
        guard interval > 0, gapPending || justExited || displacement / interval <= 120 else {
            status = "異常なGPS移動量を除外しました"
            return
        }
        savePoint(fix, segment: gapPending ? 0 : displacement, speed: trustworthySpeed, peak: peak, gap: gapPending)
        dwellStartedAt = now; currentStayStart = nil
        gapPending = false
    }

    private var distanceThreshold: Double { max(5, min(2000, UserDefaults.standard.double(forKey: "recordDistanceM") == 0 ? 25 : UserDefaults.standard.double(forKey: "recordDistanceM"))) }
    private var stayThreshold: TimeInterval { max(1, min(86400, UserDefaults.standard.double(forKey: "staySeconds") == 0 ? 60 : UserDefaults.standard.double(forKey: "staySeconds"))) }
    private var intervalThreshold: TimeInterval { max(10, UserDefaults.standard.double(forKey: "intervalSeconds") == 0 ? 30 : UserDefaults.standard.double(forKey: "intervalSeconds")) }

    private func savePoint(_ fix: CLLocation, segment: Double, speed: Double?, peak: Double?, gap: Bool) {
        let point = RoutePoint(time: fix.timestamp, latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
                               accuracy: fix.horizontalAccuracy, segment: segment, speed: speed, peak: peak, gap: gap)
        do {
            try store.add(point)
            anchor = fix
            anchorTime = fix.timestamp
            lastSavedAtSession = fix.timestamp
            lastSavedAt = fix.timestamp
            status = gap ? "欠損区間を区切って地点を保存" : "位置を記録中"
            onDataChanged?()
        } catch { status = "地点保存失敗: \(error.localizedDescription)" }
    }

    private func closeVisit() {
        if let visit = zoneVisit, visit.lastSeen.timeIntervalSince(visit.entered) >= stayThreshold {
            saveQuietly {
                try store.updateZoneVisit(zoneID: visit.zone.id, title: visit.zone.title,
                                          start: visit.entered, end: visit.lastSeen)
            }
        }
        zoneVisit = nil
        isWithinExcludedZone = false
    }

    private func saveQuietly(_ action: () throws -> Void) {
        do { try action(); onDataChanged?() }
        catch { status = "保存失敗: \(error.localizedDescription)" }
    }
}
