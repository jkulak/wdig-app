import Foundation
import Testing

@testable import WDIG

struct LocalDayTests {
    let lateEvening = Date(timeIntervalSince1970: 1_791_754_200)  // 2026-10-11 21:30:00 UTC

    @Test("A point at 21:30 UTC in Warsaw belongs to the same calendar day")
    func pointAt2130UTCInWarsawIsOnTheSameDay() {
        #expect(LocalDay.key(for: lateEvening, tz: "Europe/Warsaw") == "2026-10-11")
    }

    @Test("A point at 23:30 UTC in Warsaw belongs to the next calendar day")
    func pointAt2330UTCInWarsawIsOnTheNextDay() {
        let halfPastEleven = lateEvening.addingTimeInterval(2 * 3600)
        #expect(LocalDay.key(for: halfPastEleven, tz: "Europe/Warsaw") == "2026-10-12")
        #expect(LocalDay.key(for: halfPastEleven, tz: "America/New_York") == "2026-10-11")
    }

    @Test("The bounds of a day run from its local midnight to the next")
    func boundsRunFromLocalMidnightToTheNext() throws {
        let bounds = try #require(LocalDay.bounds(of: "2026-10-12", tz: "Europe/Warsaw"))
        #expect(bounds.start == Date(timeIntervalSince1970: 1_791_756_000))  // 2026-10-11 22:00:00 UTC
        #expect(bounds.end.timeIntervalSince(bounds.start) == 24 * 3600)
        #expect(LocalDay.bounds(of: "not a day", tz: "Europe/Warsaw") == nil)
    }
}
