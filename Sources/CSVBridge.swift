import Foundation
import UniformTypeIdentifiers
import SwiftUI

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    var contents: String
    init(contents: String = "") { self.contents = contents }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CSVError.invalid("UTF-8 CSVを読み取れません")
        }
        contents = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(contents.utf8))
    }
}

enum CSVError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return reason }; return "CSVエラー" }
}

enum CSVBridge {
    static let legacy = "timestamp,latitude,longitude,accuracy_m,segment_distance_m,cumulative_distance_km"
    static let v15 = "record_type," + legacy + ",speed_kmh,stay_end,stay_minutes,stay_anchor_timestamp"
    static let header = v15 + ",max_speed_at_point_kmh,gps_gap_link,stay_title"

    static func formatter() -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.isLenient = false
        return f
    }
    static func stamp(_ date: Date) -> String { formatter().string(from: date) }

    private static func csvCell(_ raw: String) -> String {
        let text = raw.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return text.contains(",") || text.contains("\"") ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }
    private static func line(_ columns: [String]) -> String { columns.map(csvCell).joined(separator: ",") }
    private static func f(_ value: Double, _ precision: Int) -> String { String(format: "%.*f", locale: Locale(identifier: "en_US_POSIX"), precision, value) }

    static func export(store: TrackStore, date: Date) throws -> String {
        let start = date.startOfLocalDay, end = start.nextLocalDay
        let points = try store.points(from: start, to: end)
        let stays = try store.stays(from: start, to: end)
        let visits = try store.zoneVisits(from: start, to: end)
        let speed = try store.dailyMax(on: start)
        guard !points.isEmpty || !stays.isEmpty || !visits.isEmpty || speed != nil else {
            throw CSVError.invalid("選択日の記録がありません")
        }
        var lines = ["\u{FEFF}" + header]
        var meters: Double = 0
        for p in points {
            meters += p.segment
            var row = [String](repeating: "", count: 14)
            row[0] = "POINT"; row[1] = stamp(p.time)
            row[2] = f(p.latitude, 7); row[3] = f(p.longitude, 7)
            row[4] = f(p.accuracy, 1); row[5] = f(p.segment, 2); row[6] = f(meters / 1000, 5)
            if let speed = p.speed { row[7] = f(speed * 3.6, 3) }
            if let peak = p.peak { row[11] = f(peak * 3.6, 3) }
            row[12] = p.gap ? "1" : "0"
            lines.append(line(row))
        }
        for stay in stays {
            var row = [String](repeating: "", count: 14)
            row[0] = "STAY"; row[1] = stamp(stay.start)
            row[2] = f(stay.latitude, 7); row[3] = f(stay.longitude, 7)
            row[8] = stamp(stay.end); row[9] = f(stay.duration / 60, 4)
            row[10] = stamp(stay.anchor); row[13] = stay.title
            lines.append(line(row))
        }
        for visit in visits {
            var row = [String](repeating: "", count: 14)
            row[0] = "ZONE_STAY"; row[1] = stamp(visit.start); row[8] = stamp(visit.end)
            row[9] = f(visit.duration / 60, 4); row[13] = visit.title
            lines.append(line(row))
        }
        if let speed {
            var row = [String](repeating: "", count: 14)
            row[0] = "MAX_SPEED"; row[1] = stamp(speed.time); row[7] = f(speed.metersPerSecond * 3.6, 3)
            lines.append(line(row))
        }
        let text = lines.joined(separator: "\r\n") + "\r\n"
        guard text.utf8.count <= 20 * 1024 * 1024 else { throw CSVError.invalid("CSVが20MBを超えています") }
        return text
    }

    // ダブルクォートとカンマを扱う、1物理行ずつのCSVパーサー。
    private static func parseLine(_ row: String) throws -> [String] {
        var cells: [String] = [], current = "", quoted = false
        let chars = Array(row)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                if quoted && index + 1 < chars.count && chars[index + 1] == "\"" {
                    current.append("\""); index += 1
                } else { quoted.toggle() }
            } else if char == "," && !quoted {
                cells.append(current); current = ""
            } else { current.append(char) }
            index += 1
        }
        if quoted { throw CSVError.invalid("CSVの引用符が閉じられていません") }
        cells.append(current)
        return cells
    }
    private static func parseDate(_ text: String) throws -> Date {
        let f = formatter()
        f.dateFormat = text.contains(".") ? "yyyy-MM-dd HH:mm:ss.SSS" : "yyyy-MM-dd HH:mm:ss"
        guard let date = f.date(from: text) else { throw CSVError.invalid("日時が不正です: \(text)") }
        return date
    }
    private static func numeric(_ text: String, _ label: String) throws -> Double {
        guard let n = Double(text.trimmingCharacters(in: .whitespaces)), n.isFinite else { throw CSVError.invalid("数値が不正です: \(label)") }
        return n
    }
    private static func optionalNumeric(_ text: String, _ label: String) throws -> Double? {
        text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : try numeric(text, label)
    }

    static func importFile(data: Data, into store: TrackStore) throws -> (imported: Int, skipped: Int) {
        guard data.count <= 20 * 1024 * 1024 else { throw CSVError.invalid("CSVが20MBを超えています") }
        guard let raw = String(data: data, encoding: .utf8) else { throw CSVError.invalid("UTF-8 CSVのみ対応しています") }
        let lines = raw.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard let title = lines.first?.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw CSVError.invalid("CSVが空です")
        }
        let old = title == legacy, version15 = title == v15, version16 = title == header
        guard old || version15 || version16 else { throw CSVError.invalid("RouteDiary形式ではありません") }
        guard lines.count <= 500_001 else { throw CSVError.invalid("50万行まで読み込めます") }
        let expected = old ? 6 : (version15 ? 11 : 14)
        var points: [RoutePoint] = [], stays: [StayRecord] = [], visits: [ZoneVisit] = [], speeds: [DailySpeed] = []
        // 入力を全部検証してからDB更新し、不正な行による部分インポートを防止します。
        for (index, row) in lines.dropFirst().enumerated() {
            let r = try parseLine(row)
            guard r.count == expected else { throw CSVError.invalid("\(index + 2)行目: 列数が不正です") }
            let offset = old ? 0 : 1
            let kind = old ? "POINT" : r[0].trimmingCharacters(in: .whitespaces)
            let time = try parseDate(r[offset])
            switch kind {
            case "POINT":
                let latitude = try numeric(r[offset + 1], "緯度"), longitude = try numeric(r[offset + 2], "経度")
                let accuracy = try numeric(r[offset + 3], "精度"), segment = try numeric(r[offset + 4], "距離")
                _ = try numeric(r[offset + 5], "累計距離")
                let kmh = old ? nil : try optionalNumeric(r[7], "速度")
                let peakKmh = version16 ? try optionalNumeric(r[11], "最高速度") : nil
                guard abs(latitude) <= 90, abs(longitude) <= 180, accuracy >= 0, segment >= 0,
                      (kmh == nil || (kmh! >= 0 && kmh! <= 432)),
                      (peakKmh == nil || (peakKmh! >= 0 && peakKmh! <= 432)) else {
                    throw CSVError.invalid("\(index + 2)行目: 位置・速度が不正です")
                }
                if version16 && r[12] != "0" && r[12] != "1" { throw CSVError.invalid("\(index + 2)行目: GPS欠損フラグが不正です") }
                points.append(RoutePoint(time: time, latitude: latitude, longitude: longitude, accuracy: accuracy,
                    segment: segment, speed: kmh.map { $0 / 3.6 }, peak: peakKmh.map { $0 / 3.6 }, gap: version16 && r[12] == "1"))
            case "STAY":
                let latitude = try numeric(r[2], "滞在緯度"), longitude = try numeric(r[3], "滞在経度")
                let end = try parseDate(r[8]), anchor = try parseDate(r[10]), minutes = try numeric(r[9], "滞在時間")
                guard end > time, anchor <= time, abs(latitude) <= 90, abs(longitude) <= 180,
                      abs(minutes - end.timeIntervalSince(time) / 60) <= 0.02 else {
                    throw CSVError.invalid("\(index + 2)行目: 滞在情報が不正です")
                }
                stays.append(StayRecord(anchor: anchor, start: time, end: end, latitude: latitude,
                                        longitude: longitude, title: version16 ? r[13] : ""))
            case "ZONE_STAY" where version16:
                let end = try parseDate(r[8]), minutes = try numeric(r[9], "除外時間"), name = r[13].trimmingCharacters(in: .whitespaces)
                guard end > time, !name.isEmpty, name.count <= 100,
                      abs(minutes - end.timeIntervalSince(time) / 60) <= 0.02 else {
                    throw CSVError.invalid("\(index + 2)行目: 除外エリア滞在が不正です")
                }
                visits.append(ZoneVisit(zoneID: -1, title: name, start: time, end: end))
            case "MAX_SPEED":
                let kmh = try numeric(r[7], "最高速度")
                guard kmh >= 0, kmh <= 500 else { throw CSVError.invalid("\(index + 2)行目: 最高速度が不正です") }
                speeds.append(DailySpeed(time: time, metersPerSecond: kmh / 3.6))
            default: throw CSVError.invalid("\(index + 2)行目: 未対応のレコードです")
            }
        }
        var imported = 0, skipped = 0
        for point in points {
            if try store.containsPoint(point) { skipped += 1 }
            else { try store.add(point); imported += 1 }
        }
        for stay in stays { try store.importStay(stay) }
        for visit in visits { try store.importZoneVisit(visit) }
        for speed in speeds { try store.updateDailyMax(time: speed.time, speed: speed.metersPerSecond) }
        return (imported, skipped)
    }
}
