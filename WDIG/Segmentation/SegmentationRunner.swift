import Foundation

/// Runs the segmenter over the phone's own points and keeps the store's segments in step:
/// after each batch the recorder writes, on return to the foreground, and on demand over past
/// days. Only the last two segments are ever recomputed in a normal run; everything before
/// them is closed. Segments of other devices (the demo month, a restore) are never touched.
actor SegmentationRunner {
    private let store: RecorderStore
    private let recorder: LocationRecorder
    private var settings: SegmentationSettings
    private var running = false

    init(store: RecorderStore, recorder: LocationRecorder, settings: SegmentationSettings = .load()) {
        self.store = store
        self.recorder = recorder
        self.settings = settings
    }

    func updateSettings(_ newSettings: SegmentationSettings) {
        settings = newSettings
    }

    /// Segments everything from the second-to-last segment on; nothing changes when nothing new arrived.
    func run() async {
        guard !running, let deviceId = try? await store.deviceId() else { return }
        running = true
        defer { running = false }
        let from = (try? await store.phoneSegmentStarts(ofDevice: deviceId, last: 2).first) ?? .distantPast
        await segment(deviceId: deviceId, from: from)
    }

    /// Drops every phone segment ending after the day's start and computes them again with the
    /// current settings and version.
    func resegment(fromDay day: String, tz: String) async {
        guard let deviceId = try? await store.deviceId(), let bounds = LocalDay.bounds(of: day, tz: tz) else { return }
        await segment(deviceId: deviceId, from: bounds.start)
    }

    private func segment(deviceId: UUID, from: Date) async {
        guard let points = try? await store.points(ofDevice: deviceId, from: from, to: .distantFuture) else { return }
        let existing = (try? await store.phoneSegments(ofDevice: deviceId, startingAt: from)) ?? []
        let existingSteps = Dictionary(existing.map { ($0.id, $0.steps) }, uniquingKeysWith: { first, _ in first })
        let drafts = Segmenter.segment(points, settings: settings)
        var snapshots: [SegmentSnapshot] = []
        for (index, draft) in drafts.enumerated() {
            let id = draft.stableId(deviceId: deviceId)
            var steps = existingSteps[id] ?? nil
            let closed = index < drafts.count - 1
            if closed, draft.kind == "trip", draft.modeDetected == "walking" || draft.modeDetected == "running",
                steps == nil
            {
                steps = (await recorder.steps(from: draft.startAt, to: draft.endAt)).map(Int32.init)
            }
            var snapshot = draft.snapshot(deviceId: deviceId, steps: steps)
            if let steps, draft.kind == "trip",
                let spm = StepsPolicy.cadence(steps: Int(steps), startAt: draft.startAt, endAt: draft.endAt)
            {
                let detected = spm >= settings.cadenceRunSpm ? "running" : "walking"
                if draft.modeDetected == "walking" || draft.modeDetected == "running" {
                    snapshot.modeDetected = detected
                    snapshot.modeType = detected == "running" ? "run" : "walk"
                }
            }
            snapshots.append(snapshot)
        }
        try? await store.replacePhoneSegments(ofDevice: deviceId, startingAt: from, with: snapshots)
    }
}
