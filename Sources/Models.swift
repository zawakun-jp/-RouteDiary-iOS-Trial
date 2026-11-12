import Foundation
import CoreLocation

struct RoutePoint: Identifiable {
    var id: Int64 = 0
    var time: Date
    var latitude: Double
    var longitude: Double
    var accuracy: Double
    var segment: Double
    var speed: Double?
    var peak: Double?
    var gap: Bool = false
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct StayRecord: Identifiable {
    var id: Int64 = 0
    var anchor: Date
    var start: Date
    var end: Date
    var latitude: Double
    var longitude: Double
    var title: String = ""
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct PrivacyZone: Identifiable {
    var id: Int64 = 0
    var title: String
    var latitude: Double
    var longitude: Double
    var radius: Double
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

struct ZoneVisit: Identifiable {
    var id: Int64 = 0
    var zoneID: Int64
    var title: String
    var start: Date
    var end: Date
    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

struct DailySpeed {
    var time: Date
    var metersPerSecond: Double
}

extension Date {
    var startOfLocalDay: Date { Calendar.current.startOfDay(for: self) }
    var nextLocalDay: Date { Calendar.current.date(byAdding: .day, value: 1, to: startOfLocalDay)! }
    var unixMilliseconds: Int64 { Int64((timeIntervalSince1970 * 1000).rounded()) }
    init(milliseconds: Int64) { self.init(timeIntervalSince1970: Double(milliseconds) / 1000) }
}

extension TimeInterval {
    var durationLabel: String {
        let seconds = max(0, Int(self))
        return String(format: "%d時間%02d分", seconds / 3600, (seconds % 3600) / 60)
    }
}
