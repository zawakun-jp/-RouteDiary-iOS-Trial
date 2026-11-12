import Foundation
import Combine

@MainActor
final class RouteDiaryModel: ObservableObject {
    let store: TrackStore
    let recorder: LocationRecorder

    private var followingToday = true
    @Published var selectedDay: Date = Date() {
        didSet {
            followingToday = Calendar.current.isDateInToday(selectedDay)
            refresh()
        }
    }
    @Published private(set) var points: [RoutePoint] = []
    @Published private(set) var stays: [StayRecord] = []
    @Published private(set) var zoneVisits: [ZoneVisit] = []
    @Published private(set) var zones: [PrivacyZone] = []
    @Published private(set) var maxSpeed: DailySpeed?
    @Published var message: String?

    init() throws {
        let store = try TrackStore()
        self.store = store
        self.recorder = LocationRecorder(store: store)
        recorder.onDataChanged = { [weak self] in self?.refresh() }
        refresh()
    }

    var distanceMeters: Double { points.reduce(0) { $0 + $1.segment } }
    var staySeconds: TimeInterval { stays.reduce(0) { $0 + $1.duration } }
    var excludedSeconds: TimeInterval { zoneVisits.reduce(0) { $0 + $1.duration } }
    var isTodaySelected: Bool { Calendar.current.isDateInToday(selectedDay) }

    func refresh() {
        do {
            let start = selectedDay.startOfLocalDay
            points = try store.points(from: start, to: start.nextLocalDay)
            stays = try store.stays(from: start, to: start.nextLocalDay)
            zoneVisits = try store.zoneVisits(from: start, to: start.nextLocalDay)
            maxSpeed = try store.dailyMax(on: start)
            zones = try store.zones()
        } catch { message = error.localizedDescription }
    }

    func refreshForMidnight() {
        if followingToday {
            if selectedDay.startOfLocalDay != Date().startOfLocalDay {
                selectedDay = Date() // 日付変更時は自動で今日へ追従
            } else { refresh() }
        }
        // 過去の日付を閲覧中は自動的に切り替えません。
    }

    func setZone(_ zone: PrivacyZone) {
        do { try store.saveZone(zone); refresh(); recorder.refreshZones() }
        catch { message = error.localizedDescription }
    }
    func removeZone(_ id: Int64) {
        do { try store.deleteZone(id: id); refresh(); recorder.refreshZones() }
        catch { message = error.localizedDescription }
    }
    func renameStay(_ stay: StayRecord, title: String) {
        do { try store.renameStay(anchor: stay.anchor, title: title); refresh() }
        catch { message = error.localizedDescription }
    }
    func deleteDay() {
        guard !recorder.recording else { message = "記録を停止してから削除してください"; return }
        do { try store.deleteDay(selectedDay); refresh() }
        catch { message = error.localizedDescription }
    }
    func deleteAll() {
        guard !recorder.recording else { message = "記録を停止してから削除してください"; return }
        do { try store.deleteAllHistory(); refresh() }
        catch { message = error.localizedDescription }
    }
}
