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
    private var powerObserver: PowerObserver?
    private var refreshTask: Task<Void, Never>?

    var trackingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(trackingEnabled, forKey: Self.trackingKey)
            Task { await apply() }
        }
    }
    private(set) var phaseText = "off"
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
        trackingEnabled = UserDefaults.standard.bool(forKey: Self.trackingKey)
        Task { [recorder, segmentation] in
            await recorder.setAfterFlush { await segmentation.run() }
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
        if trackingEnabled {
            let resume: ResumeTrigger = trigger == .background ? .launch : .user
            Task { await recorder.start(trigger: resume, power: PowerObserver.current()) }
        }
        startRefreshing()
    }

    func sceneBecameActive() {
        Task {
            await recorder.foregrounded()
            await segmentation.run()
            await refresh()
        }
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
        phaseText = await recorder.currentPhase().text
        events = Array(await recorder.events().suffix(30).reversed())
        authorization = LocationBridges.shared.authorizationStatus.text
        motionAuthorization = await recorder.motionAuthorization().rawValue
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
