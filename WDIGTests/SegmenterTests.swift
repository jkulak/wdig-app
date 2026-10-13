import Foundation
import Testing

@testable import WDIG

/// Fixture days made in code: a walk is points every 10 m at 1.4 m/s, a stay is points within
/// a few metres over its minutes, as the recorder would keep them.
struct Fixture {
    static let device = UUID.v7()
    static let t0 = Date(timeIntervalSince1970: 1_791_806_400)
    static let home = Coordinate(latitude: 52.2288, longitude: 21.0168)

    var points: [PointSample] = []
    var time = t0
    var here = home

    mutating func stay(minutes: Double, spread: Double = 5, every seconds: Double = 60, coordinate: Coordinate? = nil) {
        let center = coordinate ?? here
        let end = time.addingTimeInterval(minutes * 60)
        var index = 0
        while time < end {
            let spot = center.offset(north: Double(index % 3) * spread - spread, east: Double(index % 2) * spread)
            var sample = PointSample(
                deviceId: Self.device, recordedAt: time, tz: "Europe/Warsaw", latitude: spot.latitude,
                longitude: spot.longitude, hAccM: 15)
            sample.speedCms = 0
            sample.activity = 1
            sample.activityConf = 2
            points.append(sample)
            time = time.addingTimeInterval(seconds)
            index += 1
        }
        here = center
    }

    mutating func move(
        metersNorth: Double, speed: Double, activity: Int16, spacing: Double = 10, course: Int16 = 0, conf: Int16 = 2,
        skipFirst: Double = 0, wobble: Int16 = 0
    ) {
        let steps = Int(abs(metersNorth) / spacing)
        for index in 0...steps {
            let along = Double(index) * spacing * (metersNorth < 0 ? -1 : 1)
            let spot = here.offset(north: along, east: 0)
            if abs(along) >= skipFirst {
                var sample = PointSample(
                    deviceId: Self.device, recordedAt: time, tz: "Europe/Warsaw", latitude: spot.latitude,
                    longitude: spot.longitude, hAccM: 8)
                sample.speedCms = Int16(speed * 100)
                sample.courseDeg = course + (index % 2 == 0 ? 0 : wobble)
                sample.activity = activity
                sample.activityConf = conf
                points.append(sample)
            }
            time = time.addingTimeInterval(spacing / speed)
        }
        here = here.offset(north: metersNorth, east: 0)
    }

    mutating func wait(minutes: Double) {
        time = time.addingTimeInterval(minutes * 60)
    }

    /// The phone moved without a fix, as through a tunnel.
    mutating func jump(metersNorth: Double, minutes: Double) {
        time = time.addingTimeInterval(minutes * 60)
        here = here.offset(north: metersNorth, east: 0)
    }
}

struct SegmenterTests {
    let settings = SegmentationSettings()

    @Test("Seven minutes within forty metres is a stop at the median of its points")
    func sevenMinutesWithinFortyMetresIsAStop() {
        var fixture = Fixture()
        fixture.stay(minutes: 7, spread: 20)
        fixture.move(metersNorth: 500, speed: 1.4, activity: 2)
        let drafts = Segmenter.segment(fixture.points, settings: settings)
        #expect(drafts.map(\.kind) == ["stop", "trip"])
        let stop = drafts[0]
        #expect(stop.endAt.timeIntervalSince(stop.startAt) >= 300)
        let median = Coordinate.median(of: stop.points.map(\.coordinate))
        #expect(stop.centerLat == median.map { PointSample.scaled($0.latitude) })
        #expect(stop.centerLon == median.map { PointSample.scaled($0.longitude) })
    }

    @Test("A two-minute pause inside a walk stays inside the trip")
    func twoMinutePauseStaysInsideTheTrip() {
        var fixture = Fixture()
        fixture.move(metersNorth: 300, speed: 1.4, activity: 2)
        fixture.stay(minutes: 2, every: 20)
        fixture.move(metersNorth: 300, speed: 1.4, activity: 2)
        let drafts = Segmenter.segment(fixture.points, settings: settings)
        #expect(drafts.map(\.kind) == ["trip"])
    }

    @Test("A stop spans the minutes the recorder slept, when the next fix is still inside it")
    func stopSpansTheSleep() {
        var fixture = Fixture()
        fixture.stay(minutes: 8)
        fixture.wait(minutes: 50)
        fixture.stay(minutes: 1, every: 30, coordinate: Fixture.home.offset(north: 30, east: 0))
        fixture.move(metersNorth: 400, speed: 1.4, activity: 2)
        let drafts = Segmenter.segment(fixture.points, settings: settings)
        #expect(drafts.first?.kind == "stop")
        #expect((drafts.first?.endAt.timeIntervalSince(drafts.first?.startAt ?? .distantPast) ?? 0) >= 58 * 60)
    }

    @Test("The way from the door to the first fix is a dotted leg, and a tunnel is one dotted leg inside one trip")
    func doorGapAndTunnelAreDottedLegs() {
        var fixture = Fixture()
        fixture.stay(minutes: 10)
        fixture.move(metersNorth: 1_000, speed: 1.4, activity: 2, skipFirst: 400)
        var drafts = Segmenter.segment(fixture.points, settings: settings)
        #expect(drafts.map(\.kind) == ["stop", "trip"])
        var legs = Segmenter.legs(for: drafts[1], after: drafts[0], before: nil, settings: settings)
        #expect(legs.first?.dotted == true)
        #expect(legs.dropFirst().allSatisfy { !$0.dotted })

        fixture = Fixture()
        fixture.move(metersNorth: 300, speed: 1.4, activity: 2)
        fixture.jump(metersNorth: 1_000, minutes: 10)
        fixture.move(metersNorth: 300, speed: 1.4, activity: 2)
        drafts = Segmenter.segment(fixture.points, settings: settings)
        #expect(drafts.map(\.kind) == ["trip"])
        legs = Segmenter.legs(for: drafts[0], after: nil, before: nil, settings: settings)
        #expect(legs.filter(\.dotted).count == 1)
    }

    @Test("Cadence splits walking from running when the pedometer knows the trip")
    func cadenceSplitsWalkingFromRunning() {
        var fixture = Fixture()
        fixture.move(metersNorth: 1_000, speed: 2.5, activity: 2)
        let points = fixture.points
        #expect(Segmenter.segment(points, settings: settings) { _, _ in 165 }.first?.modeDetected == "running")
        #expect(Segmenter.segment(points, settings: settings) { _, _ in 165 }.first?.modeType == "run")
        #expect(Segmenter.segment(points, settings: settings) { _, _ in 110 }.first?.modeDetected == "walking")
        #expect(Segmenter.segment(points, settings: settings).first?.modeDetected == "walking")
    }

    @Test("A class with more than half the trip wins; below half the median speed decides")
    func majorityWinsOtherwiseSpeedDecides() {
        var fixture = Fixture()
        fixture.move(metersNorth: 1_100, speed: 10, activity: 5)
        fixture.move(metersNorth: 126, speed: 1.4, activity: 2)
        var drafts = Segmenter.segment(fixture.points, settings: settings)
        #expect(drafts.first?.modeDetected == "automotive")
        #expect(drafts.first?.modeConf == "medium")
        #expect(drafts.first?.modeType == "car")

        fixture = Fixture()
        fixture.move(metersNorth: 400, speed: 6, activity: 5)
        fixture.move(metersNorth: 350, speed: 6, activity: 2)
        fixture.move(metersNorth: 250, speed: 6, activity: 4)
        drafts = Segmenter.segment(fixture.points, settings: settings)
        #expect(drafts.first?.modeDetected == "cycling")
        #expect(drafts.first?.modeConf == "low")
        #expect(drafts.first?.modeType == "bike")
    }

    @Test("A straight ride over 130 km/h is a train, a bendy one or a slower one a car")
    func straightFastRideIsATrain() {
        var fixture = Fixture()
        fixture.move(metersNorth: 24_000, speed: 50, activity: 5, spacing: 50, course: 2)
        #expect(Segmenter.segment(fixture.points, settings: settings).first?.modeType == "train")

        fixture = Fixture()
        fixture.move(metersNorth: 24_000, speed: 50, activity: 5, spacing: 50, course: 0, wobble: 25)
        #expect(Segmenter.segment(fixture.points, settings: settings).first?.modeType == "car")

        fixture = Fixture()
        fixture.move(metersNorth: 24_000, speed: 33.3, activity: 5, spacing: 50, course: 2)
        #expect(Segmenter.segment(fixture.points, settings: settings).first?.modeType == "car")
    }

    @Test("Two far stops with nothing between them are a flight, two near ones nothing at all")
    func twoFarStopsAreAFlight() {
        var fixture = Fixture()
        fixture.stay(minutes: 10)
        fixture.time = fixture.time.addingTimeInterval(3 * 3_600)
        fixture.stay(minutes: 10, coordinate: Coordinate(latitude: 41.3874, longitude: 2.1686))
        var drafts = Segmenter.segment(fixture.points, settings: settings)
        #expect(drafts.map(\.kind) == ["stop", "trip", "stop"])
        #expect(drafts[1].pointCount == 0)
        #expect(drafts[1].modeType == "plane")
        #expect(abs(Double(drafts[1].distanceM) - 1_860_000) < 20_000)
        #expect(
            Segmenter.legs(for: drafts[1], after: drafts[0], before: drafts[2], settings: settings) == [
                Leg(from: drafts[0].center!, to: drafts[2].center!, dotted: true)
            ])

        fixture = Fixture()
        fixture.stay(minutes: 10)
        fixture.time = fixture.time.addingTimeInterval(3_600)
        fixture.stay(minutes: 10, coordinate: Fixture.home.offset(north: 5_000, east: 0))
        drafts = Segmenter.segment(fixture.points, settings: settings)
        #expect(drafts.map(\.kind) == ["stop", "stop"])
    }

    @Test("Poor fixes change nothing, and the same points give the same segments twice")
    func poorFixesChangeNothingAndRunsAreIdempotent() {
        var fixture = Fixture()
        fixture.stay(minutes: 10)
        fixture.move(metersNorth: 800, speed: 1.4, activity: 2)
        fixture.stay(minutes: 10)
        let clean = Segmenter.segment(fixture.points, settings: settings)
        var noisy = fixture.points
        for index in stride(from: 0, to: noisy.count, by: 20) {
            var outlier = noisy[index]
            outlier.hAccM = 500
            outlier.recordedAt = outlier.recordedAt.addingTimeInterval(1)
            outlier.lat += 5_000
            noisy.append(outlier)
        }
        #expect(Segmenter.segment(noisy, settings: settings) == clean)
        #expect(clean.map(\.kind) == ["stop", "trip", "stop"])
        let ids = clean.map { $0.stableId(deviceId: Fixture.device) }
        #expect(Set(ids).count == 3)
        #expect(
            ids == Segmenter.segment(fixture.points, settings: settings).map { $0.stableId(deviceId: Fixture.device) })
        #expect(clean[1].snapshot(deviceId: Fixture.device, steps: 900).algorithmVersion == Segmenter.algorithmVersion)
    }
}

struct SegmentationRunnerTests {
    @Test("The runner writes the phone's segments, leaves other devices alone and rebuilds the days")
    func runnerWritesThePhonesSegments() async throws {
        let store = RecorderStore(modelContainer: try Store.container(inMemory: true))
        let deviceId = try await store.ensureDevice(name: "test", appVersion: "0")
        var fixture = Fixture()
        fixture.stay(minutes: 10)
        fixture.move(metersNorth: 800, speed: 1.4, activity: 2)
        fixture.stay(minutes: 10)
        let own = fixture.points.map { point -> PointSample in
            var copy = point
            copy.deviceId = deviceId
            return copy
        }
        try await store.append(own)
        try await store.append(fixture.points)  // the fixture's own device: another device's points
        let recorder = LocationRecorder(
            store: store, activitySource: FakeActivitySource(), stepsSource: FakeStepsSource())
        let runner = SegmentationRunner(store: store, recorder: recorder)
        await runner.run()
        let day = LocalDay.key(for: Fixture.t0, tz: "Europe/Warsaw")
        let segments = try await store.segments(overlappingDay: day, tz: "Europe/Warsaw")
        #expect(segments.map(\.kind) == ["stop", "trip", "stop"])
        #expect(segments.allSatisfy { $0.deviceId == deviceId && $0.computedBy == "phone" })
        #expect(segments[1].steps != nil)
        await runner.run()
        let again = try await store.segments(overlappingDay: day, tz: "Europe/Warsaw")
        #expect(again.map(\.id) == segments.map(\.id))
        let summary = try await store.daysWithData().first { $0.localDay == day }
        #expect(summary?.tripCount == 1)
        #expect(summary?.stopCount == 2)
        // The stops absorb the first and last 75 m of the walk, as the radius rule has it.
        #expect((summary?.distanceM ?? 0) > 500)
        #expect(segments[0].center?.distance(to: Fixture.home) ?? 1_000 < 20)
    }
}
