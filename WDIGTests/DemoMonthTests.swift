import Foundation
import Testing

@testable import WDIG

struct DemoMonthTests {
    @Test("A weekday starts and ends at home with a long stay at work")
    func weekdayStartsAndEndsAtHome() {
        var generator = SeededGenerator(seed: 1)
        let day = DemoMonth.makeDay("2026-10-07", tz: "Europe/Warsaw", home: DemoMonth.home, using: &generator)
        #expect(day.segments.first?.kind == "stop")
        #expect(day.segments.last?.kind == "stop")
        #expect(day.segments.contains { $0.kind == "stop" && $0.endAt.timeIntervalSince($0.startAt) > 400 * 60 })
        #expect(day.points.count > 300)
        #expect(day.points.allSatisfy { $0.deviceId == DemoMonth.deviceId })
    }

    @Test("The same seed gives the same day")
    func sameSeedGivesTheSameDay() {
        var first = SeededGenerator(seed: 5)
        var second = SeededGenerator(seed: 5)
        let a = DemoMonth.makeDay("2026-10-03", tz: "Europe/Warsaw", home: DemoMonth.home, using: &first)
        let b = DemoMonth.makeDay("2026-10-03", tz: "Europe/Warsaw", home: DemoMonth.home, using: &second)
        #expect(a.points.count == b.points.count)
        #expect(a.points[10].lat == b.points[10].lat)
    }

    @Test("A demo month can be written and removed whole")
    func demoMonthCanBeWrittenAndRemoved() async throws {
        let store = RecorderStore(modelContainer: try Store.container(inMemory: true))
        let written = try await DemoMonth.generate(into: store, days: 2)
        #expect(written.hasPrefix("2 days"))
        #expect(try await store.pointCount() > 0)
        #expect(try await store.daysWithData().count == 2)
        _ = try await DemoMonth.remove(from: store)
        #expect(try await store.pointCount() == 0)
        #expect(try await store.daysWithData().isEmpty)
    }

    @Test("The palette gives every way of moving its own colour")
    func paletteGivesEveryTypeItsOwnColour() {
        let colours = ModeTypePalette.types.map { ModeTypePalette.color(for: $0).description }
        #expect(Set(colours).count == colours.count)
    }

    @Test("A region fits its points with a margin")
    func regionFitsItsPoints() throws {
        let region = try #require(
            DayMapModel.region(fitting: [
                .init(latitude: 52.0, longitude: 21.0), .init(latitude: 52.1, longitude: 21.2),
            ]))
        #expect(abs(region.center.latitude - 52.05) < 0.0001)
        #expect(region.span.latitudeDelta > 0.1)
    }
}
