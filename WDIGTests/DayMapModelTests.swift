import Foundation
import Testing

@testable import WDIG

@MainActor
struct DayMapModelTests {
    let device = UUID.v7()
    let noon = Date(timeIntervalSince1970: 1_791_806_400)  // 2026-10-12 12:00:00 UTC

    func makeStore() throws -> RecorderStore {
        RecorderStore(modelContainer: try Store.container(inMemory: true))
    }

    func fix(at seconds: TimeInterval, latitude: Double = 52.2297) -> PointSample {
        PointSample(
            deviceId: device, recordedAt: noon.addingTimeInterval(seconds), tz: "Europe/Warsaw", latitude: latitude,
            longitude: 21.0122, hAccM: 10)
    }

    func segment(_ kind: String, mode: String, at offset: TimeInterval) -> SegmentSnapshot {
        SegmentSnapshot(
            kind: kind, startAt: noon.addingTimeInterval(offset), endAt: noon.addingTimeInterval(offset + 1_800),
            tz: "Europe/Warsaw", modeType: mode)
    }

    func settles(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test("The map loads its day again after the store announces a write to it")
    func mapLoadsItsDayAgainAfterTheStoreAnnouncesAWriteToIt() async throws {
        let store = try makeStore()
        let model = DayMapModel(store: store, day: "2026-10-12")
        await model.load()
        #expect(model.loadCount == 1)
        #expect(model.lines.isEmpty)
        let watching = Task { await model.watch() }
        #expect(await settles { model.watching })
        try await store.append([fix(at: 0), fix(at: 60, latitude: 52.2310)])
        #expect(await settles { model.loadCount == 2 })
        #expect(model.lines.count == 1)
        #expect(model.days.map(\.localDay) == ["2026-10-12"])
        watching.cancel()
        #expect(await settles { !model.watching })
    }

    @Test("A write to another day refreshes the list of days and leaves the map as it is")
    func writeToAnotherDayRefreshesTheListOfDaysOnly() async throws {
        let store = try makeStore()
        let model = DayMapModel(store: store, day: "2026-10-12")
        await model.load()
        let watching = Task { await model.watch() }
        #expect(await settles { model.watching })
        try await store.append([fix(at: 24 * 3_600)])
        #expect(await settles { model.days.map(\.localDay) == ["2026-10-13"] })
        #expect(model.loadCount == 1)
        watching.cancel()
    }

    @Test("The legend lists the trip modes of the shown day in the palette's order, and nothing without a trip")
    func legendListsTheTripModesOfTheDayInThePalettesOrder() async throws {
        let store = try makeStore()
        try await store.upsert(segment("trip", mode: "car", at: 0))
        try await store.upsert(segment("trip", mode: "walk", at: 3_600))
        try await store.upsert(segment("stop", mode: "other", at: 7_200))
        try await store.upsert(segment("trip", mode: "car", at: 9_000))
        let model = DayMapModel(store: store, day: "2026-10-12")
        await model.load()
        #expect(model.legend == ["walk", "car"])
        model.show("2026-10-13")
        await model.load()
        #expect(model.legend.isEmpty)
    }

    @Test("A day's row reads its trips, stops and distance, or its points where it has no segments")
    func dayRowReadsItsTripsStopsAndDistanceOrItsPoints() {
        let separator = Locale.current.decimalSeparator ?? "."
        let full = DaySummarySnapshot(
            localDay: "2026-10-12", pointCount: 120, tripCount: 3, stopCount: 2, distanceM: 12_400, coarse: false)
        #expect(full.listText == "3 trips · 2 stops · 12\(separator)4 km")
        let short = DaySummarySnapshot(
            localDay: "2026-10-12", pointCount: 9, tripCount: 1, stopCount: 1, distanceM: 640, coarse: false)
        #expect(short.listText == "1 trip · 1 stop · 640 m")
        let raw = DaySummarySnapshot(
            localDay: "2026-10-12", pointCount: 1, tripCount: 0, stopCount: 0, distanceM: 0, coarse: false)
        #expect(raw.listText == "1 point")
        #expect(
            DaySummarySnapshot(
                localDay: "2026-10-12", pointCount: 5, tripCount: 0, stopCount: 0, distanceM: 0, coarse: true
            ).listText == "5 points")
    }

    @Test("A stop's dwell reads minutes under an hour, and hours with minutes from one")
    func dwellReadsMinutesThenHoursWithMinutes() {
        #expect(DayMapModel.dwell(25 * 60) == "25 min")
        #expect(DayMapModel.dwell(85 * 60) == "1 h 25 min")
    }
}
