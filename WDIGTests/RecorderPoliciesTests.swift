import Foundation
import Testing

@testable import WDIG

struct LiveKindPolicyTests {
    let now = Date(timeIntervalSince1970: 1_791_806_400)

    func speeds(_ value: Double, over seconds: Double, step: Double = 5) -> [(at: Date, speed: Double)] {
        stride(from: 0, through: seconds, by: step).map { (at: now.addingTimeInterval(-$0), speed: value) }
    }

    @Test("A minute at driving speed switches to the vehicle configuration")
    func minuteAtDrivingSpeedSwitchesToVehicle() {
        #expect(
            LiveKindPolicy.kind(current: .foot, speeds: speeds(12, over: 60), now: now, holdSeconds: 60) == .vehicle)
    }

    @Test("Thirty seconds at driving speed is not enough to switch")
    func thirtySecondsIsNotEnough() {
        #expect(LiveKindPolicy.kind(current: .foot, speeds: speeds(12, over: 30), now: now, holdSeconds: 60) == .foot)
    }

    @Test("A red light does not switch a vehicle back to foot, a minute of walking does")
    func redLightDoesNotSwitchBack() {
        var mixed = speeds(0, over: 20)
        mixed += speeds(14, over: 60).filter { now.timeIntervalSince($0.at) > 20 }
        #expect(LiveKindPolicy.kind(current: .vehicle, speeds: mixed, now: now, holdSeconds: 60) == .vehicle)
        #expect(
            LiveKindPolicy.kind(current: .vehicle, speeds: speeds(1.4, over: 60), now: now, holdSeconds: 60) == .foot)
    }

    @Test("Unknown speeds are ignored")
    func unknownSpeedsAreIgnored() {
        #expect(LiveKindPolicy.kind(current: .foot, speeds: speeds(-1, over: 60), now: now, holdSeconds: 60) == .foot)
    }
}

struct PowerPolicyTests {
    @Test("Low Power Mode asks for coarse mode whatever the level")
    func lowPowerModeAsksForCoarse() {
        #expect(PowerPolicy.wantsCoarse(PowerSnapshot(level: 0.9, state: 1, lowPowerMode: true)))
        #expect(PowerPolicy.reason(PowerSnapshot(level: 0.9, state: 1, lowPowerMode: true)) == "lowPowerMode")
    }

    @Test("A battery under twenty percent asks for coarse mode unless charging")
    func batteryUnderTwentyAsksForCoarseUnlessCharging() {
        #expect(PowerPolicy.wantsCoarse(PowerSnapshot(level: 0.19, state: 1, lowPowerMode: false)))
        #expect(!PowerPolicy.wantsCoarse(PowerSnapshot(level: 0.19, state: 2, lowPowerMode: false)))
        #expect(!PowerPolicy.wantsCoarse(PowerSnapshot(level: 0.20, state: 1, lowPowerMode: false)))
        #expect(!PowerPolicy.wantsCoarse(PowerSnapshot(level: nil, state: 0, lowPowerMode: false)))
    }

    @Test("The snapshot gives the point its battery percent and state")
    func snapshotGivesPercentAndState() {
        let power = PowerSnapshot(level: 0.734, state: 2, lowPowerMode: false)
        #expect(power.levelPercent == 73)
        #expect(power.stateCode == 2)
        #expect(PowerSnapshot.unknown.levelPercent == nil)
        #expect(PowerSnapshot.unknown.stateCode == nil)
    }
}

struct WarmPhaseTests {
    let now = Date(timeIntervalSince1970: 1_791_806_400)

    @Test("The reference of a stop is the median of the recent fixes, not their mean")
    func referenceIsTheMedian() throws {
        let recent = [52.2297, 52.2297, 52.2298, 52.2400].enumerated().map { index, latitude in
            Fix(latitude: latitude, longitude: 21.0122, timestamp: now.addingTimeInterval(Double(-60 * index)))
        }
        let reference = try #require(WarmPhase.reference(recent: recent, stationary: nil, now: now, windowSeconds: 300))
        #expect(abs(reference.latitude - 52.22975) < 0.000001)
    }

    @Test("Without recent fixes the stop fix is the reference")
    func stopFixIsTheReferenceWithoutRecentFixes() {
        let stationary = Fix(latitude: 50, longitude: 20, timestamp: now)
        let reference = WarmPhase.reference(recent: [], stationary: stationary, now: now, windowSeconds: 300)
        #expect(reference == stationary.coordinate)
    }

    @Test("A fix eighty metres from the reference means the stop is over, seventy does not")
    func eightyMetresMeansMovedOn() {
        let reference = Coordinate(latitude: 52.2297, longitude: 21.0122)
        let near = Fix(latitude: 52.2297, longitude: 21.0122 + 70 / 68_240, timestamp: now)
        let far = Fix(latitude: 52.2297, longitude: 21.0122 + 80 / 68_240, timestamp: now)
        #expect(!WarmPhase.movedOn(near, from: reference, radius: 75))
        #expect(WarmPhase.movedOn(far, from: reference, radius: 75))
    }
}

struct FixSampleTests {
    @Test("A fix becomes a point with scaled coordinates and -1 for what is unknown")
    func fixBecomesAPoint() {
        let fix = Fix(
            latitude: 52.2297123, longitude: 21.0122456, horizontalAccuracy: 7.6, altitude: 101.4, verticalAccuracy: -1,
            speed: -1, course: -1, timestamp: Date(timeIntervalSince1970: 1_791_806_400))
        let device = UUID.v7()
        let sample = fix.sample(
            deviceId: device, source: "phone", coarse: false, power: .unknown, tz: "Europe/Warsaw")
        #expect(sample.lat == 522_297_123)
        #expect(sample.lon == 210_122_456)
        #expect(sample.hAccM == 8)
        #expect(sample.altM == nil)
        #expect(sample.speedCms == -1)
        #expect(sample.courseDeg == -1)
        #expect(sample.batteryPct == nil)
        #expect(sample.deviceId == device)
    }

    @Test("Speed and course are kept in centimetres per second and whole degrees")
    func speedAndCourseAreKept() {
        let fix = Fix(
            latitude: 52, longitude: 21, horizontalAccuracy: 5, altitude: 99.6, verticalAccuracy: 3, speed: 1.389,
            course: 359.7, timestamp: Date())
        let sample = fix.sample(deviceId: .v7(), source: "phone", coarse: true, power: .unknown, tz: "Europe/Warsaw")
        #expect(sample.speedCms == 139)
        #expect(sample.courseDeg == 0)
        #expect(sample.altM == 100)
        #expect(sample.vAccM == 3)
        #expect(sample.coarse)
    }
}
