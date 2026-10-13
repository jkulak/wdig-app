import Foundation
import SwiftData
import Testing

@testable import WDIG

struct TrackingStatusTests {
    let now = Date(timeIntervalSince1970: 1_791_806_400)
    let unplugged = PowerSnapshot(level: 0.8, state: 1, lowPowerMode: false)

    @Test("Every banner state follows from its inputs")
    func everyBannerStateFollowsFromItsInputs() {
        let gap = Gap(from: now, to: now.addingTimeInterval(9_000))
        #expect(
            TrackingStatus.make(
                trackingEnabled: false, authorization: "always", phase: .live(.foot), power: unplugged, lastFixAt: now,
                openGap: nil) == .off)
        #expect(
            TrackingStatus.make(
                trackingEnabled: true, authorization: "whenInUse", phase: .live(.foot), power: unplugged,
                lastFixAt: now,
                openGap: nil) == .needsAlways)
        #expect(
            TrackingStatus.make(
                trackingEnabled: true, authorization: "denied", phase: .off, power: unplugged, lastFixAt: nil,
                openGap: nil)
                == .denied)
        #expect(
            TrackingStatus.make(
                trackingEnabled: true, authorization: "always", phase: .live(.foot), power: unplugged, lastFixAt: now,
                openGap: nil) == .on(lastFixAt: now))
        #expect(
            TrackingStatus.make(
                trackingEnabled: true, authorization: "always", phase: .coarse,
                power: PowerSnapshot(level: 0.5, state: 1, lowPowerMode: true), lastFixAt: now, openGap: nil)
                == .coarse(.lowPowerMode))
        #expect(
            TrackingStatus.make(
                trackingEnabled: true, authorization: "always", phase: .coarse,
                power: PowerSnapshot(level: 0.17, state: 1, lowPowerMode: false), lastFixAt: now, openGap: nil)
                == .coarse(.battery(percent: 17)))
        #expect(
            TrackingStatus.make(
                trackingEnabled: true, authorization: "always", phase: .asleep, power: unplugged, lastFixAt: now,
                openGap: gap) == .gap(gap))
    }
}

struct GapDetectorTests {
    /// 2026-10-12 07:00 in Warsaw.
    let morning = Date(timeIntervalSince1970: 1_791_781_200)
    let tz = "Europe/Warsaw"

    @Test("A daytime hole of two and a half hours is a gap and a hole through the night is not")
    func daytimeHoleIsAGapAndNightHoleIsNot() {
        let eight = morning.addingTimeInterval(3_600)
        let nineTen = morning.addingTimeInterval(2 * 3_600 + 600)
        let elevenForty = nineTen.addingTimeInterval(2.5 * 3_600)
        let moments = [eight, nineTen, elevenForty, elevenForty.addingTimeInterval(60)].map { GapDetector.Moment($0) }
        let gaps = GapDetector.gaps(moments: moments, now: elevenForty.addingTimeInterval(120), tz: tz)
        #expect(gaps == [Gap(from: nineTen, to: elevenForty)])

        let night = morning.addingTimeInterval(16.5 * 3_600)
        let nextMorning = night.addingTimeInterval(7 * 3_600)
        let nightMoments = [GapDetector.Moment(night), GapDetector.Moment(nextMorning)]
        #expect(GapDetector.gaps(moments: nightMoments, now: nextMorning.addingTimeInterval(60), tz: tz).isEmpty)
    }

    @Test("A hole that crosses seven in the morning is a gap")
    func holeCrossingSevenIsAGap() {
        let night = morning.addingTimeInterval(16.5 * 3_600)
        let halfPastSeven = night.addingTimeInterval(8 * 3_600)
        let moments = [GapDetector.Moment(night), GapDetector.Moment(halfPastSeven)]
        #expect(GapDetector.gaps(moments: moments, now: halfPastSeven.addingTimeInterval(60), tz: tz).count == 1)
    }

    @Test("The night the clocks go back is still a night")
    func nightTheClocksGoBackIsStillANight() {
        // 2026-10-24 23:30 CEST to 2026-10-25 06:30 CET: eight real hours, none of them daytime.
        let night = Date(timeIntervalSince1970: 1_792_877_400)
        let morningAfter = Date(timeIntervalSince1970: 1_792_906_200)
        let moments = [GapDetector.Moment(night), GapDetector.Moment(morningAfter)]
        #expect(GapDetector.gaps(moments: moments, now: morningAfter.addingTimeInterval(60), tz: tz).isEmpty)
        let halfPastSeven = Date(timeIntervalSince1970: 1_792_909_800)
        let late = [GapDetector.Moment(night), GapDetector.Moment(halfPastSeven)]
        #expect(GapDetector.gaps(moments: late, now: halfPastSeven.addingTimeInterval(60), tz: tz).count == 1)
    }

    @Test("The stretch since the last moment counts, unless the recorder went quiet on purpose")
    func stretchSinceTheLastMomentCountsUnlessQuietOnPurpose() {
        let now = morning.addingTimeInterval(3 * 3_600)
        #expect(
            GapDetector.gaps(moments: [GapDetector.Moment(morning)], now: now, tz: tz) == [Gap(from: morning, to: now)])
        let asleep = [GapDetector.Moment(morning, silenceExpected: true)]
        #expect(GapDetector.gaps(moments: asleep, now: now, tz: tz).isEmpty)
    }

    @Test("A gap is reported once, its end moves while it is open, and a dismissal holds")
    func gapIsReportedOnceAndADismissalHolds() {
        var tracker = GapTracker()
        let first = Gap(from: morning, to: morning.addingTimeInterval(3 * 3_600))
        #expect(tracker.update(with: [first], now: first.to) == [first])
        let grown = Gap(from: morning, to: morning.addingTimeInterval(4 * 3_600))
        #expect(tracker.update(with: [grown], now: grown.to).isEmpty)
        #expect(tracker.open == grown)
        #expect(tracker.dismiss() == grown)
        #expect(tracker.open == nil)
        #expect(tracker.update(with: [grown], now: grown.to).isEmpty)
        #expect(tracker.open == nil)
        let later = Gap(from: morning.addingTimeInterval(6 * 3_600), to: morning.addingTimeInterval(9 * 3_600))
        #expect(tracker.update(with: [grown, later], now: later.to) == [later])
        #expect(tracker.open == later)
    }
}

struct DiagnosticsLogTests {
    let now = Date(timeIntervalSince1970: 1_791_806_400)

    @Test("A previous run that did not stop or terminate was killed")
    func previousRunThatDidNotStopWasKilled() {
        #expect(DiagnosticsLog.previousRunKilled(lastKind: "resumed", lastAt: now) == now)
        #expect(DiagnosticsLog.previousRunKilled(lastKind: "appLaunched", lastAt: now) == now)
        #expect(DiagnosticsLog.previousRunKilled(lastKind: "stopped", lastAt: now) == nil)
        #expect(DiagnosticsLog.previousRunKilled(lastKind: "appWillTerminate", lastAt: now) == nil)
        #expect(DiagnosticsLog.previousRunKilled(lastKind: nil, lastAt: nil) == nil)
    }

    @Test("The export is a header line and one JSON object per event, named after its days")
    func exportIsAHeaderLineAndOneObjectPerEvent() throws {
        let header = DiagnosticsLog.Header(
            device: "iPhone16,1", ios: "26.0", appVersion: "1.0 (23)", build: "1.0 (23)", settings: RecorderSettings(),
            tz: "Europe/Warsaw", lowPowerMode: false)
        let events = [
            DiagnosticRecord(at: now, tz: "Europe/Warsaw", kind: "started", detail: "started (user)", batteryPct: 81),
            DiagnosticRecord(at: now.addingTimeInterval(60), tz: "Europe/Warsaw", kind: "stationary"),
        ]
        let text = try DiagnosticsLog.render(header: header, events: events)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 3)
        #expect(text.hasSuffix("\n"))
        let objects = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] ?? [:] }
        #expect(Set(objects[0].keys) == ["device", "ios", "app_version", "build", "settings", "tz", "low_power_mode"])
        #expect(objects[1]["kind"] as? String == "started")
        #expect(objects[1]["battery_pct"] as? Int == 81)
        #expect(objects[1]["at"] as? String == "2026-10-12T12:00:00Z")
        #expect(objects[2]["low_power_mode"] as? Bool == false)
        #expect(!text.contains("\"lat\"") && !text.contains("\"lon\"") && !text.contains("coordinate"))
        let from = Date(timeIntervalSince1970: 1_791_201_600)  // 2026-10-05 12:00 UTC
        #expect(
            DiagnosticsLog.fileName(from: from, to: now.addingTimeInterval(-86_400), tz: "Europe/Warsaw")
                == "wdig-diagnostics-2026-10-05-2026-10-11.jsonl")
    }

    @Test("A settings change is described field by field")
    func settingsChangeIsDescribedFieldByField() {
        var changed = RecorderSettings()
        changed.warmPhaseSeconds = 300
        changed.fenceRadiusM = 200
        #expect(
            DiagnosticsLog.changes(from: RecorderSettings(), to: changed)
                == "warmPhaseSeconds 600.0 -> 300.0, fenceRadiusM 150.0 -> 200.0")
        #expect(DiagnosticsLog.changes(from: changed, to: changed).isEmpty)
    }

    @Test("Minutes in coarse mode add up the entered-to-left stretches")
    func minutesInCoarseModeAddUp() {
        let day = "2026-10-12"
        let events = [
            DiagnosticRecord(at: now, tz: "Europe/Warsaw", kind: "coarseModeEntered"),
            DiagnosticRecord(at: now.addingTimeInterval(600), tz: "Europe/Warsaw", kind: "coarseModeLeft"),
            DiagnosticRecord(at: now.addingTimeInterval(1_200), tz: "Europe/Warsaw", kind: "coarseModeEntered"),
        ]
        #expect(DiagnosticsScreen.coarseMinutes(events, day: day, now: now.addingTimeInterval(1_800)) == 20)
        #expect(
            DiagnosticsScreen.coarseMinutes(Array(events.prefix(2)), day: day, now: now.addingTimeInterval(1_800)) == 10
        )
    }
}

struct DiagnosticsStoreTests {
    @Test("Events are kept by day, pruned after thirty days and carry no position")
    func eventsAreKeptByDayAndPruned() async throws {
        let store = RecorderStore(modelContainer: try Store.container(inMemory: true))
        let now = Date(timeIntervalSince1970: 1_791_806_400)
        try await store.logDiagnostic(
            DiagnosticRecord(at: now, tz: "Europe/Warsaw", kind: "started", detail: "started (user)"))
        try await store.logDiagnostic(
            DiagnosticRecord(at: now.addingTimeInterval(-31 * 86_400), tz: "Europe/Warsaw", kind: "stopped"))
        try await store.logDiagnostic(
            DiagnosticRecord(at: now.addingTimeInterval(-29 * 86_400), tz: "Europe/Warsaw", kind: "stopped"))
        #expect(try await store.diagnostics(onDay: "2026-10-12").map(\.kind) == ["started"])
        #expect(try await store.pruneDiagnostics(olderThan: now.addingTimeInterval(-30 * 86_400)) == 1)
        let all = try await store.diagnostics(from: .distantPast, to: .distantFuture)
        #expect(all.map(\.kind) == ["stopped", "started"])
        #expect(all.allSatisfy { !$0.detail.contains("lat") })
    }

    @Test("A store written by the first schema opens under the second with its rows intact")
    func firstSchemaStoreOpensUnderTheSecond() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "wdig-migration-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let device = UUID.v7()
        let recordedAt = Date(timeIntervalSince1970: 1_791_806_400)
        do {
            let first = Schema(versionedSchema: StoreSchemaV1.self)
            let container = try ModelContainer(
                for: first, configurations: [ModelConfiguration("V1", schema: first, url: url, cloudKitDatabase: .none)]
            )
            let context = ModelContext(container)
            context.insert(
                Point(
                    PointSample(
                        deviceId: device, recordedAt: recordedAt, tz: "Europe/Warsaw", latitude: 52.2, longitude: 21.0,
                        hAccM: 8)))
            try context.save()
        }
        let container = try ModelContainer(
            for: Store.schema, migrationPlan: StoreMigrationPlan.self,
            configurations: [ModelConfiguration("V2", schema: Store.schema, url: url, cloudKitDatabase: .none)])
        let store = RecorderStore(modelContainer: container)
        #expect(try await store.pointTimes(from: .distantPast, to: .distantFuture) == [recordedAt])
        try await store.logDiagnostic(DiagnosticRecord(at: recordedAt, tz: "Europe/Warsaw", kind: "appLaunched"))
        #expect(try await store.diagnostics(from: .distantPast, to: .distantFuture).count == 1)
    }
}
