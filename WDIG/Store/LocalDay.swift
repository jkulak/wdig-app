import Foundation

/// The local calendar day a moment belongs to, in the zone the phone was in when the
/// moment was recorded. A day is `YYYY-MM-DD` in that zone, never in the phone's current
/// zone, so a holiday abroad stays on its own days after coming home.
enum LocalDay {
    static func key(for date: Date, tz: String) -> String {
        let calendar = calendar(in: tz)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The first instant of the day and the first instant of the next one, in `tz`.
    static func bounds(of key: String, tz: String) -> (start: Date, end: Date)? {
        let numbers = key.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        let calendar = calendar(in: tz)
        var parts = DateComponents()
        parts.year = numbers[0]
        parts.month = numbers[1]
        parts.day = numbers[2]
        guard let start = calendar.date(from: parts), let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return nil }
        return (start, end)
    }

    private static func calendar(in tz: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz) ?? .gmt
        return calendar
    }
}
