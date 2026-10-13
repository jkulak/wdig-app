import Foundation
import Observation
import SwiftData
import UIKit

/// What the screens see of the recorder, on the main actor: the toggle, the phase, the
/// counts and the recent events. It owns the store and the recorder for the life of the
/// process and starts the recorder inside the launch when tracking is on.
@MainActor
@Observable
final class RecorderHub {
    static let shared = RecorderHub()
    static let trackingKey = "trackingEnabled"

    let store: RecorderStore
    private let recorder: LocationRecorder
    let segmentation: SegmentationRunner
    let diagnostics: DiagnosticsLog
    private var gaps = GapTracker.load()
    private var powerObserver: PowerObserver?
    private var refreshTask: Task<Void, Never>?

    var trackingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(trackingEnabled, forKey: Self.trackingKey)
            Task { await apply() }
        }
    }
    private(set) var phaseText = "off"
    private(set) var phase: LocationRecorder.Phase = .off
    private(set) var status: TrackingStatus = .off
    private(set) var lastFixAt: Date?
    private(set) var pointsToday = 0
    private(set) var pointsTotal = 0
    private(set) var authorization = "unknown"
    private(set) var motionAuthorization = "unknown"
    private(set) var events: [RecorderEventRecord] = []
    private(set) var storeError: String?

    init() {
        var container: ModelContainer
        var error: String?
        do {
            container = try Store.container()
        } catch let failure {
            error = failure.localizedDescription
            // A store that cannot open on disk must not take the app down; the error is shown.
            container = (try? Store.container(inMemory: true)) ?? Self.emptyContainer()
        }
        storeError = error
        store = RecorderStore(modelContainer: container)
        recorder = LocationRecorder(store: store)
        segmentation = SegmentationRunner(store: store, recorder: recorder)
        diagnostics = DiagnosticsLog(store: store)
        trackingEnabled = UserDefaults.standard.bool(forKey: Self.trackingKey)
        Task { [recorder, segmentation, diagnostics] in
            await recorder.setAfterFlush {
                await segmentation.run()
                await self.pointsFlushed()
            }
            await recorder.setEventSink { record in
                Task { await diagnostics.log(record) }
            }
        }
        powerObserver = PowerObserver { [recorder] snapshot in
            Task { await recorder.powerChanged(snapshot) }
        }
    }

    private static func emptyContainer() -> ModelContainer {
        do {
            return try ModelContainer(for: Store.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        } catch {
            fatalError("an in-memory container cannot fail to open: \(error)")
        }
    }

    /// Called from the app delegate inside the launch, so a relaunch by Core Location
    /// resumes recording before any view exists.
    func launched(trigger: LaunchTrigger) {
        let resume: ResumeTrigger = trigger == .background ? .launch : .user
        Task {
            await diagnostics.launched(trigger: trigger)
            if trackingEnabled {
                await recorder.start(trigger: resume, power: PowerObserver.current())
            }
            await checkGaps()
        }
        startRefreshing()
    }

    func willTerminate() {
        diagnostics.willTerminate()
    }

    func sceneBecameActive() {
        Task {
            await recorder.foregrounded()
            await segmentation.run()
            await checkGaps()
            await refresh()
        }
    }

    private func pointsFlushed() async {
        await checkGaps()
        await refresh()
    }

    /// Looks for a daytime hole in the last two days, logs each new one once and keeps the
    /// newest undismissed one for the banner.
    func checkGaps() async {
        let now = Date()
        let tz = TimeZone.current.identifier
        let since = now.addingTimeInterval(-48 * 3_600)
        var moments = ((try? await store.pointTimes(from: since, to: now)) ?? []).map { GapDetector.Moment($0) }
        moments += Self.moments(of: (try? await store.diagnostics(from: since, to: now)) ?? [])
        if moments.isEmpty {
            // Nothing for two days: the stretch since the last sign of life is the hole.
            let lastPoint = (try? await store.lastPoint())?.recordedAt
            let lastEvent = Self.moments(of: (try? await store.diagnostics(from: .distantPast, to: since)) ?? []).last
            moments = [lastPoint.map { GapDetector.Moment($0) }, lastEvent].compactMap { $0 }
        }
        let found = GapDetector.gaps(moments: moments, now: now, tz: tz, settings: GapSettings.load())
        for gap in gaps.update(with: found, now: now) {
            await diagnostics.log(
                "gapDetected", detail: "\(XMLOut.clock(gap.from, tz: tz)) - \(XMLOut.clock(gap.to, tz: tz))")
        }
        gaps.save()
    }

    private static func moments(of events: [DiagnosticRecord]) -> [GapDetector.Moment] {
        events.filter { DiagnosticsLog.recorderKinds.contains($0.kind) }.map {
            GapDetector.Moment($0.at, silenceExpected: DiagnosticsLog.silentKinds.contains($0.kind))
        }
    }

    func dismissGap() {
        guard let gap = gaps.dismiss() else { return }
        gaps.save()
        let tz = TimeZone.current.identifier
        Task {
            await diagnostics.log(
                "gapDismissed", detail: "\(XMLOut.clock(gap.from, tz: tz)) - \(XMLOut.clock(gap.to, tz: tz))")
            await refresh()
        }
    }

    func settingsChanged(from old: RecorderSettings, to new: RecorderSettings) async {
        await recorder.updateSettings(new)
        await diagnostics.log("settingsChanged", detail: DiagnosticsLog.changes(from: old, to: new))
    }

    private func apply() async {
        if trackingEnabled {
            await recorder.start(trigger: .user, power: PowerObserver.current())
        } else {
            await recorder.stop()
        }
        await refresh()
    }

    func refresh() async {
        let today = LocalDay.key(for: Date(), tz: TimeZone.current.identifier)
        pointsTotal = (try? await store.pointCount()) ?? 0
        pointsToday = (try? await store.pointCount(onDay: today)) ?? 0
        lastFixAt = (try? await store.lastPoint())?.recordedAt
        phase = await recorder.currentPhase()
        phaseText = phase.text
        events = Array(await recorder.events().suffix(30).reversed())
        authorization = LocationBridges.shared.authorizationStatus.text
        motionAuthorization = await recorder.motionAuthorization().rawValue
        status = TrackingStatus.make(
            trackingEnabled: trackingEnabled, authorization: authorization, phase: phase,
            power: PowerObserver.current(),
            lastFixAt: lastFixAt, openGap: gaps.open)
    }

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
