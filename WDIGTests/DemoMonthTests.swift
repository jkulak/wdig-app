import Foundation
import Testing

@testable import WDIG

struct DemoMonthTests {
    @Test("The routes fixture has every leg the plans ask for, in both directions")
    func routesFixtureHasEveryLeg() throws {
        let routes = try DemoRoutes.load()
        for (from, to, mode) in [
            ("home", "oldTown", "walk"), ("home", "vistula", "walk"), ("home", "zloteTarasy", "walk"),
            ("home", "kinoteka", "walk"),
            ("home", "lazienki", "walk"), ("home", "koszyki", "walk"), ("home", "vistula", "bike"),
            ("vistula", "lomianki", "bike"),
            ("home", "office", "car"),
        ] {
            #expect(routes.leg(from: from, to: to, mode: mode) != nil, "\(from)-\(to)-\(mode)")
            #expect(routes.leg(from: to, to: from, mode: mode) != nil, "\(to)-\(from)-\(mode)")
        }
        #expect(routes.places["home"]?.name == "Home")
    }

    @Test("A walk to the Old Town is sampled every ten metres at walking pace, after the door gap")
    func walkIsSampledEveryTenMetres() throws {
        let routes = try DemoRoutes.load()
        let leg = try #require(routes.leg(from: "home", to: "oldTown", mode: "walk"))
        var generator = SeededGenerator(seed: 3)
        let start = Date(timeIntervalSince1970: 1_791_806_400)
        let trip = DemoMonth.sample(leg: leg, mode: .walk, start: start, tz: "Europe/Warsaw", using: &generator)
        let minutes = trip.segment.endAt.timeIntervalSince(start) / 60
        #expect(minutes > 25 && minutes < 45, "\(minutes) minutes for \(trip.segment.distanceM) m")
        #expect(abs(Int(trip.segment.distanceM) - leg.distanceM) < leg.distanceM / 10)
        #expect(
            trip.points.count > leg.distanceM / 14 && trip.points.count < leg.distanceM / 8,
            "\(trip.points.count) points")
        let firstFix = try #require(trip.points.first)
        #expect(firstFix.recordedAt.timeIntervalSince(start) > 60)
        #expect(
            routes.place("home").distance(to: Coordinate(latitude: firstFix.latitude, longitude: firstFix.longitude))
                > 80)
        #expect(trip.points.allSatisfy { $0.activity == 2 && $0.speedCms > 90 && $0.speedCms < 200 })
        #expect(trip.segment.steps.map { $0 > 2_500 } == true)
    }

    @Test("A drive to the office is sampled every fifty metres with red lights")
    func driveIsSampledEveryFiftyMetres() throws {
        let routes = try DemoRoutes.load()
        let leg = try #require(routes.leg(from: "home", to: "office", mode: "car"))
        var generator = SeededGenerator(seed: 9)
        let trip = DemoMonth.sample(leg: leg, mode: .car, start: Date(), tz: "Europe/Warsaw", using: &generator)
        #expect(trip.segment.modeType == "car")
        #expect(
            trip.points.count > leg.distanceM / 70 && trip.points.count < leg.distanceM / 40,
            "\(trip.points.count) points")
        let minutes = trip.segment.endAt.timeIntervalSince(trip.segment.startAt) / 60
        #expect(minutes > 4 && minutes < 15, "\(minutes) minutes")
    }

    @Test("A weekday goes to the office by car and ends at home")
    func weekdayGoesToTheOffice() throws {
        let routes = try DemoRoutes.load()
        var generator = SeededGenerator(seed: 1)
        let day = DemoMonth.makeDay("2026-10-07", tz: "Europe/Warsaw", routes: routes, using: &generator)
        #expect(day.segments.first?.kind == "stop")
        #expect(day.segments.last?.kind == "stop")
        #expect(day.segments.contains { $0.kind == "trip" && $0.modeType == "car" })
        #expect(day.segments.contains { $0.kind == "stop" && $0.endAt.timeIntervalSince($0.startAt) > 7 * 3_600 })
        #expect(day.points.allSatisfy { $0.deviceId == DemoMonth.deviceId })
        for (earlier, later) in zip(day.segments, day.segments.dropFirst()) {
            #expect(earlier.endAt <= later.startAt.addingTimeInterval(1))
        }
    }

    @Test("The same seed gives the same day")
    func sameSeedGivesTheSameDay() throws {
        let routes = try DemoRoutes.load()
        var first = SeededGenerator(seed: 5)
        var second = SeededGenerator(seed: 5)
        let a = DemoMonth.makeDay("2026-10-03", tz: "Europe/Warsaw", routes: routes, using: &first)
        let b = DemoMonth.makeDay("2026-10-03", tz: "Europe/Warsaw", routes: routes, using: &second)
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
