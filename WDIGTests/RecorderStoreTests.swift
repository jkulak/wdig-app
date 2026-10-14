import Foundation
import SwiftData
import Testing

@testable import WDIG

struct RecorderStoreTests {
    let device = UUID.v7()
    let noon = Date(timeIntervalSince1970: 1_791_806_400)  // 2026-10-12 12:00:00 UTC

    func makeStore() throws -> RecorderStore {
        let container = try Store.container(inMemory: true)
        return RecorderStore(modelContainer: container)
    }

    func fix(at seconds: TimeInterval, tz: String = "Europe/Warsaw") -> PointSample {
        PointSample(
            deviceId: device, recordedAt: noon.addingTimeInterval(seconds), tz: tz, latitude: 52.2297,
            longitude: 21.0122, hAccM: 10)
    }

    @Test("Appended fixes come back in time order for their day")
    func appendedFixesComeBackInTimeOrder() async throws {
        let store = try makeStore()
        try await store.append([fix(at: 60), fix(at: 0), fix(at: 30)])
        let points = try await store.points(onDay: "2026-10-12")
        #expect(points.map { $0.recordedAt.timeIntervalSince(noon) } == [0, 30, 60])
        #expect(try await store.pointCount() == 3)
        #expect(try await store.lastPoint()?.recordedAt == noon.addingTimeInterval(60))
    }

    @Test("A second fix with the same device and time collapses into one row")
    func sameDeviceAndTimeCollapsesIntoOneRow() async throws {
        let store = try makeStore()
        try await store.append([fix(at: 0)])
        var again = fix(at: 0)
        again.hAccM = 50
        try await store.append([again])
        let points = try await store.points(onDay: "2026-10-12")
        #expect(points.count == 1)
        #expect(points.first?.hAccM == 50)
    }

    @Test("A fix is filed under the local day of its own time zone")
    func fixIsFiledUnderTheLocalDayOfItsZone() async throws {
        let store = try makeStore()
        try await store.append([fix(at: 11 * 3600 + 1800), fix(at: 11 * 3600 + 1800 + 1, tz: "America/New_York")])
        #expect(try await store.points(onDay: "2026-10-13").count == 1)
        #expect(try await store.points(onDay: "2026-10-12").count == 1)
    }

    @Test("The list of days counts the points of each day and marks a coarse one")
    func listOfDaysCountsPointsAndMarksCoarse() async throws {
        let store = try makeStore()
        var coarse = fix(at: 24 * 3600)
        coarse.coarse = true
        try await store.append([fix(at: 0), fix(at: 10), coarse])
        let days = try await store.daysWithData()
        #expect(days.map(\.localDay) == ["2026-10-13", "2026-10-12"])
        #expect(days.map(\.pointCount) == [1, 2])
        #expect(days.map(\.coarse) == [true, false])
    }

    @Test("The list of days counts each day's trips, stops and distance from its segments")
    func listOfDaysCountsTripsStopsAndDistanceFromSegments() async throws {
        let store = try makeStore()
        try await store.append([fix(at: 0)])
        let plan: [(offset: TimeInterval, kind: String, metres: Int32)] = [
            (0, "stop", 0), (1_800, "trip", 5_000), (3_600, "stop", 0), (5_400, "trip", 4_000), (7_200, "trip", 3_400),
        ]
        for step in plan {
            try await store.upsert(
                SegmentSnapshot(
                    kind: step.kind, startAt: noon.addingTimeInterval(step.offset),
                    endAt: noon.addingTimeInterval(step.offset + 1_200), tz: "Europe/Warsaw", distanceM: step.metres))
        }
        let days = try await store.daysWithData()
        #expect(days.map(\.localDay) == ["2026-10-12"])
        #expect(days.first?.tripCount == 3)
        #expect(days.first?.stopCount == 2)
        #expect(days.first?.distanceM == 12_400)
    }

    @Test("A trip crossing midnight counts on both days, its distance split by the time on each")
    func tripCrossingMidnightCountsOnBothDays() async throws {
        let store = try makeStore()
        try await store.append([fix(at: 0), fix(at: 24 * 3_600)])
        let lateEvening = Date(timeIntervalSince1970: 1_791_838_800)  // 2026-10-12 23:00 Warsaw
        try await store.upsert(
            SegmentSnapshot(
                kind: "trip", startAt: lateEvening, endAt: lateEvening.addingTimeInterval(2 * 3_600),
                tz: "Europe/Warsaw", distanceM: 3_000))
        let days = try await store.daysWithData()
        #expect(days.map(\.localDay) == ["2026-10-13", "2026-10-12"])
        #expect(days.map(\.tripCount) == [1, 1])
        #expect(days.map(\.distanceM) == [1_500, 1_500])
    }

    @Test("A write announces the days it touched to whoever subscribed")
    func writeAnnouncesTheDaysItTouched() async throws {
        let store = try makeStore()
        var changes = store.changes.subscribe().makeAsyncIterator()
        try await store.append([fix(at: 0), fix(at: 24 * 3_600)])
        #expect(await changes.next()?.days == ["2026-10-12", "2026-10-13"])
        try await store.upsert(
            SegmentSnapshot(kind: "stop", startAt: noon, endAt: noon.addingTimeInterval(600), tz: "Europe/Warsaw"))
        #expect(await changes.next()?.days == ["2026-10-12"])
    }

    @Test("A segment crossing midnight is stored once and returned on both days")
    func segmentCrossingMidnightIsReturnedOnBothDays() async throws {
        let store = try makeStore()
        let elevenPM = Date(timeIntervalSince1970: 1_791_752_400)  // 2026-10-11 23:00 Warsaw
        let segment = SegmentSnapshot(
            kind: "trip", startAt: elevenPM, endAt: elevenPM.addingTimeInterval(2 * 3600), tz: "Europe/Warsaw")
        try await store.upsert(segment)
        #expect(try await store.segments(overlappingDay: "2026-10-11", tz: "Europe/Warsaw").map(\.id) == [segment.id])
        #expect(try await store.segments(overlappingDay: "2026-10-12", tz: "Europe/Warsaw").map(\.id) == [segment.id])
        #expect(try await store.segments(overlappingDay: "2026-10-13", tz: "Europe/Warsaw").isEmpty)
    }

    @Test("A soft-deleted segment is not returned")
    func softDeletedSegmentIsNotReturned() async throws {
        let store = try makeStore()
        var segment = SegmentSnapshot(
            kind: "stop", startAt: noon, endAt: noon.addingTimeInterval(600), tz: "Europe/Warsaw")
        segment.deletedAt = noon
        try await store.upsert(segment)
        #expect(try await store.segments(overlappingDay: "2026-10-12", tz: "Europe/Warsaw").isEmpty)
    }

    @Test("The device row keeps its id across calls")
    func deviceRowKeepsItsId() async throws {
        let store = try makeStore()
        let first = try await store.ensureDevice(name: "iPhone15,2", appVersion: "0.1.0 (1)")
        let second = try await store.ensureDevice(name: "iPhone15,2", appVersion: "0.1.0 (2)")
        #expect(first == second)
        #expect(first.version == 7)
    }

    @Test("A day of three thousand fixes is read back in well under a second")
    func dayOfThreeThousandFixesIsReadBackQuickly() async throws {
        let store = try makeStore()
        for batch in 0..<150 {
            try await store.append((0..<20).map { fix(at: TimeInterval(batch * 20 + $0)) })
        }
        let started = Date()
        let points = try await store.points(onDay: "2026-10-12")
        #expect(points.count == 3000)
        #expect(Date().timeIntervalSince(started) < 1)
    }
}
