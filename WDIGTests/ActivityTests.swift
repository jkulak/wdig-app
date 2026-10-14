import CoreMotion
import Foundation
import Testing

@testable import WDIG

struct ActivityCodeTests {
    @Test("Automotive wins over stationary at a red light, running over walking, unknown over all")
    func fasterClassWinsAndUnknownWins() {
        #expect(
            ActivityCode.code(
                stationary: true, walking: false, running: false, cycling: false, automotive: true, unknown: false) == 5
        )
        #expect(
            ActivityCode.code(
                stationary: false, walking: true, running: true, cycling: false, automotive: false, unknown: false) == 3
        )
        #expect(
            ActivityCode.code(
                stationary: false, walking: false, running: false, cycling: false, automotive: false, unknown: false)
                == 0)
        #expect(
            ActivityCode.code(
                stationary: false, walking: true, running: false, cycling: false, automotive: false, unknown: true) == 0
        )
        #expect(
            ActivityCode.code(
                stationary: true, walking: false, running: false, cycling: false, automotive: false, unknown: false)
                == 1)
        #expect(
            ActivityCode.code(
                stationary: false, walking: false, running: false, cycling: true, automotive: false, unknown: false)
                == 4)
    }

    @Test("Confidence maps to 0, 1 and 2 and the classes to the recorder's ways of moving")
    func confidenceAndKinds() {
        #expect(ActivityCode.confidence(.low) == 0)
        #expect(ActivityCode.confidence(.medium) == 1)
        #expect(ActivityCode.confidence(.high) == 2)
        #expect(ActivityCode.kind(for: 5) == .vehicle)
        #expect(ActivityCode.kind(for: 4) == .cycle)
        #expect(ActivityCode.kind(for: 2) == .foot)
        #expect(ActivityCode.kind(for: 3) == .foot)
        #expect(ActivityCode.kind(for: 1) == nil)
        #expect(ActivityCode.kind(for: 0) == nil)
    }
}

struct ActivityTimelineTests {
    let t0 = Date(timeIntervalSince1970: 1_791_806_400)

    @Test("A fix gets the class in force at its time, and unknown before the first sample")
    func fixGetsTheClassInForce() {
        var timeline = ActivityTimeline()
        timeline.add(ActivitySample(code: 2, confidence: 2, startDate: t0))
        timeline.add(ActivitySample(code: 5, confidence: 1, startDate: t0.addingTimeInterval(60)))
        #expect(timeline.sample(at: t0.addingTimeInterval(30)).code == 2)
        #expect(timeline.sample(at: t0.addingTimeInterval(30)).confidence == 2)
        #expect(timeline.sample(at: t0.addingTimeInterval(90)).code == 5)
        #expect(timeline.sample(at: t0.addingTimeInterval(90)).confidence == 1)
        #expect(timeline.sample(at: t0.addingTimeInterval(-10)).code == 0)
        #expect(timeline.sample(at: t0.addingTimeInterval(-10)).confidence == 0)
    }

    @Test("The back-fill never asks for more than the seven days Core Motion keeps")
    func backfillNeverAsksForMoreThanSevenDays() {
        let now = t0
        #expect(BackfillPolicy.range(lastStamped: nil, now: now).from == now.addingTimeInterval(-7 * 86_400))
        #expect(
            BackfillPolicy.range(lastStamped: now.addingTimeInterval(-10 * 86_400), now: now).from
                == now.addingTimeInterval(-7 * 86_400))
        #expect(
            BackfillPolicy.range(lastStamped: now.addingTimeInterval(-86_400), now: now).from
                == now.addingTimeInterval(-86_400))
        #expect(BackfillPolicy.range(lastStamped: nil, now: now).to == now)
    }

    @Test("A class has to hold for the hold time before the configuration switches")
    func classHasToHoldBeforeTheSwitch() {
        #expect(
            ClassKindPolicy.kind(
                current: .foot, desired: .vehicle, desiredSince: t0, now: t0.addingTimeInterval(30), holdSeconds: 60)
                == .foot)
        #expect(
            ClassKindPolicy.kind(
                current: .foot, desired: .vehicle, desiredSince: t0, now: t0.addingTimeInterval(60), holdSeconds: 60)
                == .vehicle)
        #expect(
            ClassKindPolicy.kind(current: .vehicle, desired: nil, desiredSince: nil, now: t0, holdSeconds: 60)
                == .vehicle)
        #expect(
            ClassKindPolicy.kind(current: .vehicle, desired: .vehicle, desiredSince: t0, now: t0, holdSeconds: 60)
                == .vehicle)
    }
}

struct ActivityBackfillTests {
    let device = UUID.v7()
    let t0 = Date(timeIntervalSince1970: 1_791_806_400)

    func fix(at seconds: TimeInterval, uploaded: Bool = false) -> PointSample {
        var sample = PointSample(
            deviceId: device, recordedAt: t0.addingTimeInterval(seconds), tz: "Europe/Warsaw", latitude: 52.23,
            longitude: 21.01, hAccM: 10)
        if uploaded {
            sample.uploadBatchId = UUID.v7()
        }
        return sample
    }

    @Test("A back-fill restamps the unknown points that were not uploaded and leaves the rest alone")
    func backfillRestampsOnlyUnknownUnuploadedPoints() async throws {
        let store = RecorderStore(modelContainer: try Store.container(inMemory: true))
        try await store.append((0..<50).map { fix(at: TimeInterval($0) * 10) })
        try await store.append((50..<60).map { fix(at: TimeInterval($0) * 10, uploaded: true) })
        let samples = [ActivitySample(code: 2, confidence: 2, startDate: t0.addingTimeInterval(-5))]
        let changed = try await store.restampActivity(
            from: t0.addingTimeInterval(-60), to: t0.addingTimeInterval(700), samples: samples)
        #expect(changed == 50)
        let points = try await store.points(from: t0, to: t0.addingTimeInterval(700))
        #expect(points.filter { $0.activity == 2 && $0.activityConf == 2 }.count == 50)
        #expect(points.filter { $0.uploadBatchId != nil }.allSatisfy { $0.activity == 0 })
        #expect(try await store.latestStampedPointDate() == t0.addingTimeInterval(490))
        #expect(try await store.restampActivity(from: t0, to: t0.addingTimeInterval(700), samples: samples) == 0)
    }

    @Test("The back-fill's log line names its range in UTC to the minute and the points it stamped")
    func backfillLogLineNamesItsRangeAndTheStampedPoints() {
        let event = RecorderEvent.activityBackfilled(
            from: Date(timeIntervalSince1970: 1_791_784_800), to: Date(timeIntervalSince1970: 1_791_792_000), count: 50)
        #expect(event.text == "backfill 2026-10-12T06:00Z–2026-10-12T08:00Z, 50 points")
    }
}

struct StepsTests {
    let t0 = Date(timeIntervalSince1970: 1_791_806_400)

    @Test("A trip older than seven days is not asked about, a younger one is")
    func tripOlderThanSevenDaysIsNotAskedAbout() {
        #expect(!StepsPolicy.canQuery(startAt: t0.addingTimeInterval(-8 * 86_400), now: t0))
        #expect(StepsPolicy.canQuery(startAt: t0.addingTimeInterval(-6 * 86_400), now: t0))
    }

    @Test("Cadence is steps per minute of the trip")
    func cadenceIsStepsPerMinute() {
        #expect(StepsPolicy.cadence(steps: 4000, startAt: t0, endAt: t0.addingTimeInterval(40 * 60)) == 100)
        #expect(StepsPolicy.cadence(steps: nil, startAt: t0, endAt: t0.addingTimeInterval(60)) == nil)
        #expect(StepsPolicy.cadence(steps: 10, startAt: t0, endAt: t0) == nil)
    }

    @Test("The fake pedometer answers for exactly the range asked")
    func fakePedometerAnswersForTheRange() async throws {
        let source = FakeStepsSource()
        source.stepsPerMinute = 120
        let steps = try await source.steps(from: t0, to: t0.addingTimeInterval(40 * 60))
        #expect(steps == 4800)
        #expect(source.queries.count == 1)
        #expect(source.queries.first?.to == t0.addingTimeInterval(40 * 60))
    }
}
