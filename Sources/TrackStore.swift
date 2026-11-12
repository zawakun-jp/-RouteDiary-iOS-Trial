import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

enum TrackStoreError: LocalizedError {
    case database(String)
    var errorDescription: String? {
        if case .database(let text) = self { return text }
        return "保存データの処理に失敗しました"
    }
}

// Android TrackDb v4 と同じカラム名・ミリ秒時刻を使用します。
// GPS処理とDB操作はメインスレッドで直列実行し、SQLite接続を共有します。
final class TrackStore {
    private var database: OpaquePointer?

    init() throws {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = base.appendingPathComponent("RouteDiary", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("route_diary.sqlite")
        if sqlite3_open(file.path, &database) != SQLITE_OK {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite open"
            sqlite3_close(database); database = nil
            throw TrackStoreError.database(message)
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS points(id INTEGER PRIMARY KEY AUTOINCREMENT,time INTEGER NOT NULL,lat REAL NOT NULL,lon REAL NOT NULL,accuracy REAL NOT NULL,segment REAL NOT NULL,speed REAL,peak_speed REAL,gap INTEGER NOT NULL DEFAULT 0)")
        try execute("CREATE INDEX IF NOT EXISTS points_time ON points(time)")
        try execute("CREATE TABLE IF NOT EXISTS stays(id INTEGER PRIMARY KEY AUTOINCREMENT,anchor_time INTEGER NOT NULL,start_time INTEGER NOT NULL,end_time INTEGER NOT NULL,lat REAL NOT NULL,lon REAL NOT NULL,title TEXT NOT NULL DEFAULT '',UNIQUE(anchor_time,start_time))")
        try execute("CREATE INDEX IF NOT EXISTS stays_start ON stays(start_time)")
        try execute("CREATE TABLE IF NOT EXISTS max_speeds(day_start INTEGER PRIMARY KEY,time INTEGER NOT NULL,speed REAL NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS zones(id INTEGER PRIMARY KEY AUTOINCREMENT,title TEXT NOT NULL,lat REAL NOT NULL,lon REAL NOT NULL,radius REAL NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS zone_stays(id INTEGER PRIMARY KEY AUTOINCREMENT,zone_id INTEGER NOT NULL,zone_title TEXT NOT NULL,start_time INTEGER NOT NULL,end_time INTEGER NOT NULL,UNIQUE(zone_id,start_time))")
        try execute("CREATE INDEX IF NOT EXISTS zone_stays_start ON zone_stays(start_time)")
    }

    deinit { sqlite3_close(database) }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TrackStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw TrackStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
    }
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Int64) { sqlite3_bind_int64(statement, index, value) }
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double) { sqlite3_bind_double(statement, index, value) }
    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) { sqlite3_bind_text(statement, index, value, -1, sqliteTransient) }
    private func nullable(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
        if let value, value.isFinite { bind(statement, index, value) } else { sqlite3_bind_null(statement, index) }
    }
    private func checkStep(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw TrackStoreError.database(String(cString: sqlite3_errmsg(database)))
        }
    }
    private func textValue(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: bytes)
    }
    private func optionalDouble(_ statement: OpaquePointer, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    func add(_ point: RoutePoint) throws {
        let s = try prepare("INSERT INTO points(time,lat,lon,accuracy,segment,speed,peak_speed,gap) VALUES(?,?,?,?,?,?,?,?)")
        defer { sqlite3_finalize(s) }
        bind(s, 1, point.time.unixMilliseconds); bind(s, 2, point.latitude); bind(s, 3, point.longitude)
        bind(s, 4, point.accuracy); bind(s, 5, point.segment)
        nullable(s, 6, point.speed); nullable(s, 7, point.peak)
        bind(s, 8, Int64(point.gap ? 1 : 0)); try checkStep(s)
    }

    func points(from: Date, to: Date) throws -> [RoutePoint] {
        let s = try prepare("SELECT id,time,lat,lon,accuracy,segment,speed,peak_speed,gap FROM points WHERE time>=? AND time<? ORDER BY time,id")
        defer { sqlite3_finalize(s) }
        bind(s, 1, from.unixMilliseconds); bind(s, 2, to.unixMilliseconds)
        var results: [RoutePoint] = []
        while sqlite3_step(s) == SQLITE_ROW {
            results.append(RoutePoint(id: sqlite3_column_int64(s, 0), time: Date(milliseconds: sqlite3_column_int64(s, 1)),
                latitude: sqlite3_column_double(s, 2), longitude: sqlite3_column_double(s, 3), accuracy: sqlite3_column_double(s, 4),
                segment: sqlite3_column_double(s, 5), speed: optionalDouble(s, 6), peak: optionalDouble(s, 7), gap: sqlite3_column_int(s, 8) == 1))
        }
        return results
    }

    func updateStay(anchor: Date, start: Date, end: Date, latitude: Double, longitude: Double) throws {
        guard end > start else { return }
        var part = start
        while part < end {
            let stop = min(end, part.nextLocalDay)
            let s = try prepare("INSERT INTO stays(anchor_time,start_time,end_time,lat,lon,title) VALUES(?,?,?,?,?,'') ON CONFLICT(anchor_time,start_time) DO UPDATE SET end_time=MAX(end_time,excluded.end_time)")
            bind(s, 1, anchor.unixMilliseconds); bind(s, 2, part.unixMilliseconds); bind(s, 3, stop.unixMilliseconds)
            bind(s, 4, latitude); bind(s, 5, longitude)
            defer { sqlite3_finalize(s) }
            try checkStep(s)
            part = stop
        }
    }

    func stays(from: Date, to: Date) throws -> [StayRecord] {
        let s = try prepare("SELECT id,anchor_time,start_time,end_time,lat,lon,title FROM stays WHERE start_time<? AND end_time>? ORDER BY start_time")
        defer { sqlite3_finalize(s) }
        bind(s, 1, to.unixMilliseconds); bind(s, 2, from.unixMilliseconds)
        var results: [StayRecord] = []
        while sqlite3_step(s) == SQLITE_ROW {
            results.append(StayRecord(id: sqlite3_column_int64(s, 0), anchor: Date(milliseconds: sqlite3_column_int64(s, 1)),
                start: max(from, Date(milliseconds: sqlite3_column_int64(s, 2))),
                end: min(to, Date(milliseconds: sqlite3_column_int64(s, 3))),
                latitude: sqlite3_column_double(s, 4), longitude: sqlite3_column_double(s, 5), title: textValue(s, 6)))
        }
        return results.filter { $0.end > $0.start }
    }

    func renameStay(anchor: Date, title: String) throws {
        let s = try prepare("UPDATE stays SET title=? WHERE anchor_time=?")
        defer { sqlite3_finalize(s) }
        bind(s, 1, title); bind(s, 2, anchor.unixMilliseconds); try checkStep(s)
    }

    func updateDailyMax(time: Date, speed: Double) throws {
        guard speed.isFinite, speed >= 1, speed <= 120 else { return }
        let s = try prepare("INSERT INTO max_speeds(day_start,time,speed) VALUES(?,?,?) ON CONFLICT(day_start) DO UPDATE SET time=excluded.time,speed=excluded.speed WHERE excluded.speed>max_speeds.speed")
        defer { sqlite3_finalize(s) }
        bind(s, 1, time.startOfLocalDay.unixMilliseconds); bind(s, 2, time.unixMilliseconds); bind(s, 3, speed)
        try checkStep(s)
    }

    func dailyMax(on date: Date) throws -> DailySpeed? {
        let s = try prepare("SELECT time,speed FROM max_speeds WHERE day_start=?")
        defer { sqlite3_finalize(s) }
        bind(s, 1, date.startOfLocalDay.unixMilliseconds)
        guard sqlite3_step(s) == SQLITE_ROW else { return nil }
        return DailySpeed(time: Date(milliseconds: sqlite3_column_int64(s, 0)), metersPerSecond: sqlite3_column_double(s, 1))
    }

    func zones() throws -> [PrivacyZone] {
        let s = try prepare("SELECT id,title,lat,lon,radius FROM zones ORDER BY title COLLATE NOCASE,id")
        defer { sqlite3_finalize(s) }
        var result: [PrivacyZone] = []
        while sqlite3_step(s) == SQLITE_ROW {
            result.append(PrivacyZone(id: sqlite3_column_int64(s, 0), title: textValue(s, 1),
                latitude: sqlite3_column_double(s, 2), longitude: sqlite3_column_double(s, 3), radius: sqlite3_column_double(s, 4)))
        }
        return result
    }

    func saveZone(_ zone: PrivacyZone) throws {
        let sql = zone.id > 0 ? "UPDATE zones SET title=?,lat=?,lon=?,radius=? WHERE id=?" : "INSERT INTO zones(title,lat,lon,radius) VALUES(?,?,?,?)"
        let s = try prepare(sql)
        defer { sqlite3_finalize(s) }
        bind(s, 1, zone.title); bind(s, 2, zone.latitude); bind(s, 3, zone.longitude); bind(s, 4, zone.radius)
        if zone.id > 0 { bind(s, 5, zone.id) }
        try checkStep(s)
    }

    func deleteZone(id: Int64) throws {
        let s = try prepare("DELETE FROM zones WHERE id=?")
        defer { sqlite3_finalize(s) }
        bind(s, 1, id); try checkStep(s)
    }

    // 除外エリア滞在にはGPS座標を一切保存しません。
    func updateZoneVisit(zoneID: Int64, title: String, start: Date, end: Date) throws {
        guard end > start, !title.isEmpty else { return }
        var part = start
        while part < end {
            let stop = min(end, part.nextLocalDay)
            let s = try prepare("INSERT INTO zone_stays(zone_id,zone_title,start_time,end_time) VALUES(?,?,?,?) ON CONFLICT(zone_id,start_time) DO UPDATE SET end_time=MAX(end_time,excluded.end_time),zone_title=excluded.zone_title")
            bind(s, 1, zoneID); bind(s, 2, title); bind(s, 3, part.unixMilliseconds); bind(s, 4, stop.unixMilliseconds)
            defer { sqlite3_finalize(s) }
            try checkStep(s)
            part = stop
        }
    }

    func zoneVisits(from: Date, to: Date) throws -> [ZoneVisit] {
        let s = try prepare("SELECT id,zone_id,zone_title,start_time,end_time FROM zone_stays WHERE start_time<? AND end_time>? ORDER BY start_time")
        defer { sqlite3_finalize(s) }
        bind(s, 1, to.unixMilliseconds); bind(s, 2, from.unixMilliseconds)
        var result: [ZoneVisit] = []
        while sqlite3_step(s) == SQLITE_ROW {
            result.append(ZoneVisit(id: sqlite3_column_int64(s, 0), zoneID: sqlite3_column_int64(s, 1), title: textValue(s, 2),
                start: max(from, Date(milliseconds: sqlite3_column_int64(s, 3))), end: min(to, Date(milliseconds: sqlite3_column_int64(s, 4)))))
        }
        return result.filter { $0.end > $0.start }
    }

    func containsPoint(_ p: RoutePoint) throws -> Bool {
        let s = try prepare("SELECT 1 FROM points WHERE time BETWEEN ? AND ? AND ABS(lat-?)<0.000005 AND ABS(lon-?)<0.000005 LIMIT 1")
        defer { sqlite3_finalize(s) }
        bind(s, 1, p.time.unixMilliseconds - 1000); bind(s, 2, p.time.unixMilliseconds + 1000)
        bind(s, 3, p.latitude); bind(s, 4, p.longitude)
        return sqlite3_step(s) == SQLITE_ROW
    }
    func importStay(_ stay: StayRecord) throws {
        let s = try prepare("INSERT INTO stays(anchor_time,start_time,end_time,lat,lon,title) VALUES(?,?,?,?,?,?) ON CONFLICT(anchor_time,start_time) DO UPDATE SET end_time=MAX(end_time,excluded.end_time),title=CASE WHEN excluded.title!='' THEN excluded.title ELSE stays.title END")
        defer { sqlite3_finalize(s) }
        bind(s, 1, stay.anchor.unixMilliseconds); bind(s, 2, stay.start.unixMilliseconds); bind(s, 3, stay.end.unixMilliseconds)
        bind(s, 4, stay.latitude); bind(s, 5, stay.longitude); bind(s, 6, stay.title)
        try checkStep(s)
    }
    func importZoneVisit(_ visit: ZoneVisit) throws {
        let existing = try prepare("SELECT zone_id FROM zone_stays WHERE start_time=? AND zone_title=? LIMIT 1")
        defer { sqlite3_finalize(existing) }
        bind(existing, 1, visit.start.unixMilliseconds); bind(existing, 2, visit.title)
        if sqlite3_step(existing) == SQLITE_ROW {
            try updateZoneVisit(zoneID: sqlite3_column_int64(existing, 0), title: visit.title, start: visit.start, end: visit.end)
            return
        }
        // インポート行と実エリアのIDを衝突させないため負の値を使います。
        let stableID = -1 - Int64(fnv1a(visit.title))
        try updateZoneVisit(zoneID: stableID, title: visit.title, start: visit.start, end: visit.end)
    }
    private func fnv1a(_ text: String) -> UInt32 {
        var hash: UInt32 = 2166136261
        for byte in text.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
        return hash
    }

    // Cloud API v2.1 とAndroid版 OnlineSync のページ形式に合わせたローカル全件読み出し。
    // DBオブジェクトは @MainActor 上でのみ参照し、ネットワーク応答中はアクセスしません。
    func cloudPage(type: String, afterID: Int64, limit: Int = 200) throws -> (items: [[String: Any]], next: Int64) {
        let capped = max(1, min(200, limit))
        let sql: String
        switch type {
        case "points":
            sql = "SELECT id,time,lat,lon,accuracy,segment,speed,peak_speed,gap FROM points WHERE id>? ORDER BY id LIMIT \(capped)"
        case "stays":
            sql = "SELECT id,anchor_time,start_time,end_time,lat,lon,title FROM stays WHERE id>? ORDER BY id LIMIT \(capped)"
        case "max_speeds":
            sql = "SELECT day_start,time,speed FROM max_speeds WHERE day_start>? ORDER BY day_start LIMIT \(capped)"
        default: throw TrackStoreError.database("未対応のクラウドデータ種別")
        }
        let s = try prepare(sql)
        defer { sqlite3_finalize(s) }
        bind(s, 1, afterID)
        var output: [[String: Any]] = []
        var next = afterID
        while sqlite3_step(s) == SQLITE_ROW {
            next = sqlite3_column_int64(s, 0)
            switch type {
            case "points":
                output.append([
                    "time": sqlite3_column_int64(s, 1),
                    "lat": sqlite3_column_double(s, 2), "lon": sqlite3_column_double(s, 3),
                    "accuracy": sqlite3_column_double(s, 4), "segment": sqlite3_column_double(s, 5),
                    "speed_mps": optionalDouble(s, 6) as Any? ?? NSNull(),
                    "peak_speed_mps": optionalDouble(s, 7) as Any? ?? NSNull(),
                    "gps_gap": sqlite3_column_int(s, 8) != 0
                ])
            case "stays":
                output.append([
                    "anchor_time": sqlite3_column_int64(s, 1),
                    "start_time": sqlite3_column_int64(s, 2), "end_time": sqlite3_column_int64(s, 3),
                    "lat": sqlite3_column_double(s, 4), "lon": sqlite3_column_double(s, 5),
                    "title": textValue(s, 6)
                ])
            default:
                output.append([
                    "day_start": sqlite3_column_int64(s, 0),
                    "time": sqlite3_column_int64(s, 1), "speed_mps": sqlite3_column_double(s, 2)
                ])
            }
        }
        return (output, next)
    }

    func importCloudRecords(_ type: String, items: [[String: Any]]) throws -> Int {
        func number(_ json: [String: Any], _ key: String) throws -> Double {
            guard let v = json[key] as? NSNumber, v.doubleValue.isFinite else {
                throw TrackStoreError.database("クラウドから受信した \(key) が不正です")
            }
            return v.doubleValue
        }
        func millis(_ json: [String: Any], _ key: String) throws -> Int64 {
            let value = try number(json, key)
            guard value >= 0, value < 32_503_680_000_000 else {
                throw TrackStoreError.database("クラウド日時 \(key) が不正です")
            }
            return Int64(value)
        }
        var added = 0
        for json in items {
            switch type {
            case "points":
                let timestamp = Date(milliseconds: try millis(json, "time"))
                let lat = try number(json, "lat"), lon = try number(json, "lon")
                let accuracy = try number(json, "accuracy"), segment = try number(json, "segment")
                guard abs(lat) <= 90, abs(lon) <= 180, accuracy >= 0, accuracy <= 10_000,
                      segment >= 0, segment <= 1_000_000 else { throw TrackStoreError.database("クラウド位置情報が不正です") }
                let speed = (json["speed_mps"] as? NSNumber)?.doubleValue
                let peak = (json["peak_speed_mps"] as? NSNumber)?.doubleValue
                guard (speed == nil || (speed!.isFinite && speed! >= 0 && speed! <= 120)),
                      (peak == nil || (peak!.isFinite && peak! >= 0 && peak! <= 120)) else {
                    throw TrackStoreError.database("クラウド速度が不正です")
                }
                let point = RoutePoint(time: timestamp, latitude: lat, longitude: lon, accuracy: accuracy,
                    segment: segment, speed: speed, peak: peak, gap: json["gps_gap"] as? Bool ?? false)
                if try !containsPoint(point) { try add(point); added += 1 }
            case "stays":
                let anchor = Date(milliseconds: try millis(json, "anchor_time"))
                let start = Date(milliseconds: try millis(json, "start_time"))
                let end = Date(milliseconds: try millis(json, "end_time"))
                let lat = try number(json, "lat"), lon = try number(json, "lon")
                let title = json["title"] as? String ?? ""
                guard end > start, anchor <= start, abs(lat) <= 90, abs(lon) <= 180, title.count <= 200 else {
                    throw TrackStoreError.database("クラウド滞在情報が不正です")
                }
                try importStay(StayRecord(anchor: anchor, start: start, end: end, latitude: lat, longitude: lon, title: title))
            case "max_speeds":
                let timestamp = Date(milliseconds: try millis(json, "time"))
                let speed = try number(json, "speed_mps")
                guard speed >= 0, speed <= 120 else { throw TrackStoreError.database("クラウド最高速度が不正です") }
                try updateDailyMax(time: timestamp, speed: speed)
            default: throw TrackStoreError.database("未対応のクラウドデータ種別")
            }
        }
        return added
    }

    func deleteDay(_ day: Date) throws {
        let from = day.startOfLocalDay.unixMilliseconds, to = day.nextLocalDay.unixMilliseconds
        for (table, col) in [("points", "time"), ("stays", "start_time"), ("max_speeds", "day_start"), ("zone_stays", "start_time")] {
            let s = try prepare("DELETE FROM \(table) WHERE \(col)>=? AND \(col)<?")
            bind(s, 1, from); bind(s, 2, to); defer { sqlite3_finalize(s) }; try checkStep(s)
        }
    }

    func deleteAllHistory() throws {
        for table in ["points", "stays", "max_speeds", "zone_stays"] { try execute("DELETE FROM \(table)") }
    }
}
