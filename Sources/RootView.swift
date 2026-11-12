import SwiftUI
import MapKit
import CoreLocation
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var model: RouteDiaryModel
    @StateObject private var dashboard = DashboardSettings()
    @StateObject private var cloud = CloudClient()
    @AppStorage("appDarkMode") private var dark = false
    @AppStorage("appLanguage") private var language = "ja"
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { DiaryMapView(model: model) }
                .tabItem { Label(rd("地図"), systemImage: "map") }.tag(0)
            NavigationStack { HistoryView(model: model) }
                .tabItem { Label(rd("履歴"), systemImage: "clock.arrow.circlepath") }.tag(1)
            NavigationStack { PrivacyZonesView(model: model) }
                .tabItem { Label(rd("除外"), systemImage: "eye.slash") }.tag(2)
            NavigationStack { CloudBackupView(model: model) }
                .tabItem { Label(rd("クラウド"), systemImage: "icloud") }.tag(3)
            NavigationStack { SettingsView(model: model) }
                .tabItem { Label(rd("設定"), systemImage: "gearshape") }.tag(4)
        }
        .environmentObject(dashboard)
        .environmentObject(cloud)
        .preferredColorScheme(dark ? .dark : .light)
        .environment(\.locale, Locale(identifier: language == "zh" ? "zh_Hans" : language == "en" ? "en" : "ja"))
        .id(language)
        .alert("RouteDiary", isPresented: Binding(
            get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) { model.message = nil }
            } message: { Text(model.message ?? "") }
        .onReceive(Timer.publish(every: 15, on: .main, in: .common).autoconnect()) { _ in
            model.refreshForMidnight()
        }
        .task { if cloud.signedIn { await cloud.refreshAvatar() } }
    }
}

struct DailyMetricsView: View {
    @ObservedObject var model: RouteDiaryModel
    @EnvironmentObject private var dashboard: DashboardSettings

    private func metricValue(_ id: String) -> String {
        switch id {
        case "points": return "\(model.points.count)"
        case "distance": return String(format: "%.2f km", model.distanceMeters / 1000)
        case "peak": return String(format: "%.1f km/h", (model.maxSpeed?.metersPerSecond ?? 0) * 3.6)
        case "stay": return "\(model.staySeconds.durationLabel) / \(model.stays.count)回"
        case "current_stay": return model.currentStaySeconds.durationLabel
        case "zone_total": return model.excludedSeconds.durationLabel
        default: return ""
        }
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                DatePicker(rd("表示日"), selection: $model.selectedDay, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.compact)
                Spacer()
                Button(rd("今日")) { model.selectedDay = Date() }.font(.caption)
            }
            let visible = dashboard.entries.filter { $0.visible }
            if !visible.isEmpty {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(visible) { entry in
                        VStack(spacing: 3) {
                            Text(DashboardSettings.label(entry.id)).font(.system(size: 10)).foregroundStyle(.secondary)
                                .lineLimit(2).multilineTextAlignment(.center)
                            Text(metricValue(entry.id)).font(.system(size: 12, weight: .semibold))
                                .minimumScaleFactor(0.65).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 40)
                        .padding(.horizontal, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}

struct DiaryMapView: View {
    @ObservedObject var model: RouteDiaryModel
    @ObservedObject private var recorder: LocationRecorder
    @EnvironmentObject private var cloud: CloudClient
    @AppStorage("recordPinsVisible") private var showPins = true
    @AppStorage("liveMarkerAvatar") private var useAvatar = false
    @AppStorage("mapSatellite") private var satellite = false
    @State private var camera: MapCameraPosition = .region(MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.6812, longitude: 139.7671),
        span: MKCoordinateSpan(latitudeDelta: 0.025, longitudeDelta: 0.025)))
    @State private var following = false
    @State private var didAutoCenter = false
    @State private var chooseZone = false
    @State private var compassEnabled = false
    @State private var accountOpen = false
    @State private var selectedPoint: RoutePoint?
    @State private var draftLocation: ZoneDraftCoordinate?

    init(model: RouteDiaryModel) {
        self.model = model
        self.recorder = model.recorder
    }

    private var routeSegments: [[CLLocationCoordinate2D]] {
        var groups: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []
        for point in model.points {
            if point.gap {
                if current.count >= 2 { groups.append(current) }
                current = [point.coordinate]
            } else { current.append(point.coordinate) }
        }
        if current.count >= 2 { groups.append(current) }
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            DailyMetricsView(model: model).padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ZStack(alignment: .bottomTrailing) {
                MapReader { proxy in
                    Map(position: $camera) {
                        ForEach(routeSegments.indices, id: \.self) { i in
                            MapPolyline(coordinates: routeSegments[i])
                                .stroke(.blue, lineWidth: 4)
                        }
                        ForEach(model.zones) { zone in
                            MapCircle(center: zone.coordinate, radius: zone.radius)
                                .foregroundStyle(.red.opacity(0.13))
                                .stroke(.red.opacity(0.85), lineWidth: 1.5)
                        }
                        ForEach(model.zones) { zone in
                            Annotation(zone.title, coordinate: zone.coordinate) {
                                Image(systemName: "eye.slash.fill")
                                    .font(.footnote).foregroundStyle(.white)
                                    .padding(5).background(.red, in: Circle())
                            }
                        }
                        if showPins {
                            ForEach(model.points.suffix(350)) { point in
                                Annotation("記録地点", coordinate: point.coordinate) {
                                    Button { selectedPoint = point } label: {
                                        Image(systemName: "mappin.circle.fill")
                                            .font(.system(size: 14)).foregroundStyle(.blue)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        ForEach(model.stays) { stay in
                            Annotation(stay.title.isEmpty ? "滞在" : stay.title, coordinate: stay.coordinate) {
                                Image(systemName: "mappin.circle.fill")
                                    .foregroundStyle(.orange)
                                    .font(.title3)
                            }
                        }
                        if let location = recorder.currentLocation {
                            Annotation("現在地", coordinate: location.coordinate) {
                                if useAvatar, let avatar = cloud.avatarImage {
                                    Image(uiImage: avatar).resizable().scaledToFill()
                                        .frame(width: 36, height: 36).clipShape(Circle())
                                        .overlay(Circle().stroke(.blue, lineWidth: 2))
                                } else {
                                    Image(systemName: "location.circle.fill")
                                        .font(.title2).foregroundStyle(.white, .blue)
                                        .shadow(radius: 2)
                                }
                            }
                        }
                    }
                    .mapStyle(satellite ? .imagery(elevation: .flat) : .standard(elevation: .flat))
                    .mapControls { MapCompass(); MapScaleView() }
                    .onTapGesture { point in
                        if chooseZone, let coord = proxy.convert(point, from: .local) {
                            draftLocation = ZoneDraftCoordinate(coordinate: coord)
                            chooseZone = false
                        }
                    }
                    // 地図を長押しして除外エリア位置を指定できます。
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.65)
                            .sequenced(before: DragGesture(minimumDistance: 0))
                            .onEnded { value in
                                if case .second(true, let drag?) = value,
                                   let coordinate = proxy.convert(drag.location, from: .local) {
                                    draftLocation = ZoneDraftCoordinate(coordinate: coordinate)
                                    chooseZone = false
                                }
                            }
                    )
                }
                VStack(alignment: .trailing, spacing: 8) {
                    if chooseZone {
                        Text(rd("地図上の登録位置をタップ"))
                            .font(.caption).bold().padding(8)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                    }
                    Spacer()
                    control("square.3.layers.3d") { satellite.toggle() }
                    Button {
                        compassEnabled.toggle()
                        recorder.setCompassEnabled(compassEnabled)
                        if compassEnabled, let fix = recorder.currentLocation { focus(fix.coordinate) }
                    } label: {
                        Image("compass")
                            .resizable().scaledToFit().frame(width: 37, height: 37)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(compassEnabled ? .blue : .clear, lineWidth: 2))
                            .frame(width: 42, height: 42)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).accessibilityLabel("方位磁石の切り替え")
                    control("location") {
                        following = true
                        recorder.requestOneShotLocation()
                        if let fix = recorder.currentLocation { focus(fix.coordinate) }
                    }
                    control("rectangle.expand.vertical") {
                        following = false; compassEnabled = false; recorder.setCompassEnabled(false)
                        fitAll()
                    }
                    control("plus.circle") { chooseZone.toggle() }
                }
                .padding(12)
            }
            .onChange(of: recorder.currentLocation?.timestamp) { _, _ in
                if let location = recorder.currentLocation,
                   following || (!didAutoCenter && model.isTodaySelected) {
                    focus(location.coordinate)
                    didAutoCenter = true
                }
            }
            .onChange(of: model.selectedDay) { _, _ in fitAll() }
            .onChange(of: recorder.headingDegrees) { _, heading in
                if compassEnabled, let degrees = heading, let fix = recorder.currentLocation {
                    camera = .camera(MapCamera(centerCoordinate: fix.coordinate, distance: 800,
                                               heading: degrees, pitch: 0))
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle().fill(recorder.recording ? .green : .gray).frame(width: 8, height: 8)
                        Text(recorder.status).font(.caption).lineLimit(2)
                        Spacer()
                        if let speed = recorder.speedKmh {
                            Text(String(format: "%.1f km/h", speed)).font(.caption).monospacedDigit()
                        }
                    }
                    Button(action: { recorder.recording ? recorder.stop() : recorder.start() }) {
                        Label(recorder.recording ? "GPS記録を停止" : "GPS記録を開始",
                              systemImage: recorder.recording ? "stop.circle.fill" : "record.circle")
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(recorder.recording ? .red : .blue)
                }
                .padding(10)
                .background(.regularMaterial)
            }
        }
        .navigationTitle("RouteDiary")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { accountOpen = true } label: {
                    if let avatar = cloud.avatarImage {
                        Image(uiImage: avatar).resizable().scaledToFill().frame(width: 30, height: 30).clipShape(Circle())
                    } else { Image(systemName: "person.crop.circle").font(.title2) }
                }.accessibilityLabel(rd("アカウント"))
            }
        }
        .sheet(isPresented: $accountOpen) { AccountView() }
        .sheet(item: $selectedPoint) { point in
            NavigationStack {
                Form {
                    LabeledContent("記録日時", value: point.time.formatted())
                    LabeledContent("緯度", value: String(format: "%.7f", point.latitude))
                    LabeledContent("経度", value: String(format: "%.7f", point.longitude))
                    LabeledContent("測位精度", value: String(format: "%.1f m", point.accuracy))
                    LabeledContent("区間距離", value: String(format: "%.1f m", point.segment))
                    if let speed = point.speed { LabeledContent("速度", value: String(format: "%.1f km/h", speed * 3.6)) }
                    if point.gap { Text(rd("GPS欠損・除外区間の後のため距離加算なし")) }
                }
                .navigationTitle(rd("地点の情報"))
                .toolbar { ToolbarItem(placement: .topBarTrailing) {
                    Button("×") { selectedPoint = nil }
                } }
            }.presentationDetents([.medium, .large])
        }
        .onAppear { if !model.points.isEmpty { fitAll() } }
        .onDisappear { if compassEnabled { compassEnabled = false; recorder.setCompassEnabled(false) } }
        .sheet(item: $draftLocation) { location in
            ZoneFormView(coordinate: location.coordinate, onSave: { zone in model.setZone(zone) })
        }
    }

    private func control(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3).frame(width: 42, height: 42)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }.buttonStyle(.plain)
    }
    private func focus(_ point: CLLocationCoordinate2D) {
        camera = .region(MKCoordinateRegion(center: point, span: MKCoordinateSpan(latitudeDelta: 0.007, longitudeDelta: 0.007)))
    }
    private func fitAll() {
        let coords = model.points.map(\.coordinate)
        guard let first = coords.first else { return }
        let minLat = coords.map(\.latitude).min() ?? first.latitude
        let maxLat = coords.map(\.latitude).max() ?? first.latitude
        let minLon = coords.map(\.longitude).min() ?? first.longitude
        let maxLon = coords.map(\.longitude).max() ?? first.longitude
        camera = .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max(0.007, (maxLat - minLat) * 1.4),
                                   longitudeDelta: max(0.007, (maxLon - minLon) * 1.4))))
    }
}

// sheet(item:)で使う位置のラッパー（CoreLocation型を拡張しない）
struct ZoneDraftCoordinate: Identifiable {
    let id = UUID()
    let coordinate: CLLocationCoordinate2D
}

struct PrivacyZonesView: View {
    @ObservedObject var model: RouteDiaryModel
    @ObservedObject private var recorder: LocationRecorder
    @State private var editing: PrivacyZone?
    @State private var addAtCurrentLocation = false

    init(model: RouteDiaryModel) { self.model = model; self.recorder = model.recorder }

    var body: some View {
        List {
            Section {
                Button {
                    if let fix = recorder.currentLocation {
                        editing = PrivacyZone(title: "新しい除外エリア", latitude: fix.coordinate.latitude,
                                              longitude: fix.coordinate.longitude, radius: 100)
                    } else { addAtCurrentLocation = true; recorder.requestOneShotLocation() }
                } label: { Label(rd("現在地を除外エリアに追加"), systemImage: "plus.circle") }
                Text(rd("地図上の任意位置からも追加できます（地図タブの＋）。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section(rd("登録済みエリア")) {
                if model.zones.isEmpty { Text(rd("除外エリアはありません")).foregroundStyle(.secondary) }
                ForEach(model.zones) { zone in
                    Button {
                        editing = zone
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(zone.title).foregroundStyle(.primary)
                            Text("半径 \(Int(zone.radius))m  •  \(zone.latitude.formatted(.number.precision(.fractionLength(5)))), \(zone.longitude.formatted(.number.precision(.fractionLength(5))))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { model.removeZone(model.zones[index].id) }
                }
            }
            Section {
                Text(rd("除外エリア内ではGPS座標を履歴に保存しません。滞在時間のみ日別に集計します。"))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(rd("記録除外エリア"))
        .onChange(of: recorder.currentLocation?.timestamp) { _, _ in
            guard addAtCurrentLocation, let fix = recorder.currentLocation else { return }
            addAtCurrentLocation = false
            editing = PrivacyZone(title: "新しい除外エリア", latitude: fix.coordinate.latitude,
                                  longitude: fix.coordinate.longitude, radius: 100)
        }
        .sheet(item: $editing) { zone in
            ZoneFormView(coordinate: zone.coordinate, existingZone: zone,
                         onSave: { newZone in model.setZone(newZone) })
        }
    }
}

struct ZoneFormView: View {
    @Environment(\.dismiss) private var dismiss
    let coordinate: CLLocationCoordinate2D
    let existingZone: PrivacyZone?
    let onSave: (PrivacyZone) -> Void
    @State private var title: String
    @State private var radius: Double

    init(coordinate: CLLocationCoordinate2D, existingZone: PrivacyZone? = nil, onSave: @escaping (PrivacyZone) -> Void) {
        self.coordinate = coordinate; self.existingZone = existingZone; self.onSave = onSave
        _title = State(initialValue: existingZone?.title ?? "新しい除外エリア")
        _radius = State(initialValue: existingZone?.radius ?? 100)
    }
    var body: some View {
        NavigationStack {
            Form {
                TextField(rd("エリア名"), text: $title)
                VStack(alignment: .leading) {
                    Text("半径 \(Int(radius)) m")
                    Slider(value: $radius, in: 10...5000, step: 10)
                }
                Text(String(format: "緯度 %.6f / 経度 %.6f", coordinate.latitude, coordinate.longitude))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle(rd("除外エリアを設定"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(rd("キャンセル")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(rd("保存")) {
                        onSave(PrivacyZone(id: existingZone?.id ?? 0, title: title.trimmingCharacters(in: .whitespaces),
                                           latitude: coordinate.latitude, longitude: coordinate.longitude, radius: radius))
                        dismiss()
                    }.disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
