import CoreLocation
import Foundation
import os

/// The recorder: every decision about Core Location is made in this actor, which drives it
/// through `LocationProviding`. It spends the battery budget on purpose: live updates only
/// while moving, a short hundred-metre warm phase after a stop so a false stop costs little,
/// nothing at all while the phone sits, and wake-ups iOS pays for (a geofence exit, a
/// significant change).
actor LocationRecorder {
    enum Phase: Sendable, Equatable {
        case off
        case live(MovementKind)
        case warm
        case asleep
        case coarse

        var text: String {
            switch self {
            case .off: "off"
            case .live(let kind): "recording (\(kind))"
            case .warm: "warm phase after a stop"
            case .asleep: "asleep, fence set"
            case .coarse: "coarse mode"
            }
        }
    }

    static let flushCount = 20
    static let flushSeconds: Double = 60

    private let store: RecorderStore
    private let locationSource: any LocationProviding
    private let activitySource: any ActivityProviding
    private let stepsSource: any StepsProviding
    /// What the recorder waits on: the warm timer and the flush timer. An existential rather
    /// than a type parameter, so the hub, the runner and the bridges hold a recorder without
    /// becoming generic over two sleep calls. The moments the recorder writes down stay
    /// `Date`s: they are compared with Core Location's and Core Motion's, which no `Clock` gives.
    private let clock: any Clock<Duration>
    private let logger = Logger(subsystem: "com.jkulak.wdig", category: "recorder")
    private var settings: RecorderSettings
    private var timeline = ActivityTimeline()
    private var desiredKind: MovementKind?
    private var desiredSince: Date?
    private(set) var phase: Phase = .off
    private var deviceId: UUID?
    private var liveTask: Task<Void, Never>?
    private var warmTimer: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var lastKept: Fix?
    private var recentKept: [Fix] = []
    private var speeds: [(at: Date, speed: Double)] = []
    private var reference: Coordinate?
    private var hasFence = false
    private var pending: [PointSample] = []
    private var power: PowerSnapshot = .unknown
    private var recentEvents: [RecorderEventRecord] = []
    private var afterFlush: (@Sendable () async -> Void)?
    private var eventSink: (@Sendable (RecorderEventRecord) -> Void)?

    init(
        store: RecorderStore, locationSource: any LocationProviding, clock: any Clock<Duration>,
        settings: RecorderSettings = .load(), activitySource: any ActivityProviding = CoreMotionActivitySource(),
        stepsSource: any StepsProviding = PedometerStepsSource()
    ) {
        self.store = store
        self.locationSource = locationSource
        self.clock = clock
        self.settings = settings
        self.activitySource = activitySource
        self.stepsSource = stepsSource
    }

    // MARK: - Control

    func start(trigger: ResumeTrigger, power: PowerSnapshot) async {
        guard phase == .off else { return }
        self.power = power
        do {
            deviceId = try await store.ensureDevice(name: DeviceInfo.model, appVersion: DeviceInfo.appVersion)
        } catch {
            note(.error("store: \(error.localizedDescription)"))
            return
        }
        await locationSource.start(for: self)
        activitySource.startUpdates { [weak self] sample in
            Task { await self?.activityChanged(sample) }
        }
        note(.activityUpdatesStarted)
        Task { [weak self] in await self?.backfillActivity() }
        note(.started(trigger: trigger))
        if PowerPolicy.wantsCoarse(power) {
            await enterCoarse(reason: PowerPolicy.reason(power))
        } else {
            startLive(.foot)
        }
    }

    func stop() async {
        guard phase != .off else { return }
        liveTask?.cancel()
        liveTask = nil
        warmTimer?.cancel()
        warmTimer = nil
        await removeFence()
        await locationSource.stop()
        activitySource.stopUpdates()
        note(.activityUpdatesStopped)
        phase = .off
        await flush()
        note(.stopped)
    }

    /// The app came to the front: the classes Core Motion kept while the process was away
    /// fill the points recorded without one.
    func foregrounded() async {
        guard phase != .off else { return }
        await backfillActivity()
    }

    func motionAuthorization() -> MotionAuthorization {
        activitySource.authorization
    }

    // MARK: - Motion classes and steps

    func activityChanged(_ sample: ActivitySample) {
        timeline.add(sample)
        let desired = ActivityCode.kind(for: sample.code)
        if desired != desiredKind {
            desiredKind = desired
            desiredSince = sample.startDate
        }
    }

    private func backfillActivity() async {
        let lastStamped = try? await store.latestStampedPointDate()
        let range = BackfillPolicy.range(lastStamped: lastStamped, now: Date())
        do {
            let samples = try await activitySource.history(from: range.from, to: range.to)
            if let last = samples.last {
                timeline.add(last)
            }
            let count = try await store.restampActivity(from: range.from, to: range.to, samples: samples)
            note(.activityBackfilled(count: count))
        } catch {
            note(.error("activity history: \(error.localizedDescription)"))
        }
    }

    /// The pedometer's count for a closed trip, when it is young enough to be known.
    func steps(from start: Date, to end: Date) async -> Int? {
        guard StepsPolicy.canQuery(startAt: start, now: Date()) else { return nil }
        do {
            let steps = try await stepsSource.steps(from: start, to: end)
            note(.stepsQueried(steps: steps))
            return steps
        } catch {
            note(.error("pedometer: \(error.localizedDescription)"))
            return nil
        }
    }

    func powerChanged(_ snapshot: PowerSnapshot) async {
        power = snapshot
        guard phase != .off else { return }
        if PowerPolicy.wantsCoarse(snapshot), phase != .coarse {
            await enterCoarse(reason: PowerPolicy.reason(snapshot))
        } else if !PowerPolicy.wantsCoarse(snapshot), phase == .coarse {
            await leaveCoarse()
        }
    }

    func updateSettings(_ newSettings: RecorderSettings) {
        settings = newSettings
    }

    /// What runs once a batch of points is in the store: the segmenter.
    func setAfterFlush(_ work: @escaping @Sendable () async -> Void) {
        afterFlush = work
    }

    func currentPhase() -> Phase {
        phase
    }

    func events() -> [RecorderEventRecord] {
        recentEvents
    }

    /// Where every event goes besides the recent list: the diagnostics log.
    func setEventSink(_ sink: @escaping @Sendable (RecorderEventRecord) -> Void) {
        eventSink = sink
    }

    func note(_ event: RecorderEvent) {
        let record = RecorderEventRecord(at: Date(), event: event)
        recentEvents.append(record)
        eventSink?(record)
        if recentEvents.count > 200 {
            recentEvents.removeFirst(recentEvents.count - 200)
        }
        logger.info("\(event.text, privacy: .public)")
    }

    // MARK: - Live updates

    private func startLive(_ kind: MovementKind) {
        liveTask?.cancel()
        phase = .live(kind)
        liveTask = Task { [weak self, locationSource] in
            do {
                for try await update in await locationSource.liveUpdates(kind) {
                    if Task.isCancelled { return }
                    guard let self else { return }
                    await self.handle(update)
                }
            } catch {
                if !Task.isCancelled {
                    await self?.note(.error("live updates: \(error.localizedDescription)"))
                }
            }
        }
    }

    private func handle(_ update: LiveUpdate) async {
        guard case .live(let kind) = phase else { return }
        if update.authorizationDenied {
            note(.error("live updates: authorization denied"))
            return
        }
        if update.stationary {
            note(.stationary)
            await beginWarmPhase(stationary: update.fix)
            return
        }
        guard let fix = update.fix else { return }
        let now = fix.timestamp
        speeds.append((at: now, speed: fix.speed))
        speeds.removeAll { now.timeIntervalSince($0.at) > settings.classHoldSeconds * 2 }
        await keep(fix, kind: kind, source: "phone", coarse: false)
        let next: MovementKind
        if activitySource.authorization == .authorized {
            next = ClassKindPolicy.kind(
                current: kind, desired: desiredKind, desiredSince: desiredSince, now: now,
                holdSeconds: settings.classHoldSeconds)
        } else {
            next = LiveKindPolicy.kind(current: kind, speeds: speeds, now: now, holdSeconds: settings.classHoldSeconds)
        }
        if next != kind {
            note(.configurationChanged(from: kind, to: next))
            startLive(next)
        }
    }

    // MARK: - The stop: warm phase, fence, wake

    private func beginWarmPhase(stationary: Fix?) async {
        liveTask?.cancel()
        liveTask = nil
        phase = .warm
        let now = stationary?.timestamp ?? Date()
        reference = WarmPhase.reference(
            recent: recentKept, stationary: stationary, now: now, windowSeconds: settings.referenceWindowSeconds)
        note(.warmPhaseBegan)
        await locationSource.startWarm()
        let seconds = settings.warmPhaseSeconds
        warmTimer = Task { [weak self, clock] in
            try? await clock.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.warmPhaseExpired()
        }
        await flush()
    }

    func warmFixes(_ fixes: [Fix]) async {
        guard phase == .warm, let reference else { return }
        for fix in fixes {
            await keep(fix, kind: .foot, source: "phone", coarse: false)
            if WarmPhase.movedOn(fix, from: reference, radius: settings.stopRadiusM) {
                await resumeLive(trigger: .motion)
                return
            }
        }
    }

    private func warmPhaseExpired() async {
        guard phase == .warm else { return }
        await locationSource.stopWarm()
        phase = .asleep
        if let reference {
            await locationSource.setFence(around: reference, radius: settings.fenceRadiusM)
            hasFence = true
        }
        note(.warmPhaseEnded)
        await flush()
    }

    /// The fence around the stop was left: the sleeping recorder wakes.
    func fenceExited() async {
        guard phase == .asleep else { return }
        await resumeLive(trigger: .fenceExit)
    }

    func significantChangeFixes(_ fixes: [Fix]) async {
        switch phase {
        case .asleep:
            for fix in fixes {
                await keep(fix, kind: .foot, source: "significant_change", coarse: false)
            }
            await resumeLive(trigger: .significantChange)
        case .coarse:
            for fix in fixes {
                await keep(fix, kind: .vehicle, source: "significant_change", coarse: true)
            }
            await flush()
        case .off, .live, .warm:
            break
        }
    }

    func visit(_ visit: VisitSample) async {
        guard phase == .coarse, let deviceId else { return }
        let fix = Fix(
            latitude: visit.coordinate.latitude, longitude: visit.coordinate.longitude,
            horizontalAccuracy: visit.horizontalAccuracy, altitude: 0, verticalAccuracy: -1,
            timestamp: visit.arrival ?? Date())
        pending.append(
            fix.sample(deviceId: deviceId, source: "visit", coarse: true, power: power, tz: TimeZone.current.identifier)
        )
        await flush()
    }

    private func resumeLive(trigger: ResumeTrigger) async {
        warmTimer?.cancel()
        warmTimer = nil
        await locationSource.stopWarm()
        await removeFence()
        note(.resumed(trigger: trigger))
        startLive(.foot)
    }

    private func removeFence() async {
        guard hasFence else { return }
        await locationSource.removeFence()
        hasFence = false
    }

    // MARK: - Coarse mode

    private func enterCoarse(reason: String) async {
        liveTask?.cancel()
        liveTask = nil
        warmTimer?.cancel()
        warmTimer = nil
        await locationSource.stopWarm()
        await removeFence()
        phase = .coarse
        await locationSource.startVisits()
        note(.coarseModeEntered(reason: reason))
        await flush()
    }

    private func leaveCoarse() async {
        await locationSource.stopVisits()
        note(.coarseModeLeft)
        startLive(.foot)
    }

    func authorizationChanged(_ status: CLAuthorizationStatus) {
        note(.authorizationChanged(status.text))
    }

    // MARK: - Keeping fixes

    private func keep(_ fix: Fix, kind: MovementKind, source: String, coarse: Bool) async {
        guard let deviceId else { return }
        guard Thinning.shouldKeep(fix, after: lastKept, kind: kind, settings: settings) else { return }
        lastKept = fix
        recentKept.append(fix)
        recentKept.removeAll { fix.timestamp.timeIntervalSince($0.timestamp) > settings.referenceWindowSeconds }
        var sample = fix.sample(
            deviceId: deviceId, source: source, coarse: coarse, power: power, tz: TimeZone.current.identifier)
        let activity = timeline.sample(at: fix.timestamp)
        sample.activity = activity.code
        sample.activityConf = activity.confidence
        pending.append(sample)
        if pending.count >= Self.flushCount {
            await flush()
        } else if flushTask == nil {
            flushTask = Task { [weak self, clock] in
                try? await clock.sleep(for: .seconds(Self.flushSeconds))
                guard !Task.isCancelled else { return }
                await self?.flush()
            }
        }
    }

    func flush() async {
        flushTask?.cancel()
        flushTask = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        pending = []
        do {
            try await store.append(batch)
            if let afterFlush {
                Task { await afterFlush() }
            }
        } catch {
            pending.insert(contentsOf: batch, at: 0)
            note(.error("store: \(error.localizedDescription)"))
        }
    }
}

/// The phone and the build, for the device row.
enum DeviceInfo {
    static var model: String {
        var system = utsname()
        uname(&system)
        return withUnsafePointer(to: &system.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }

    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0"
        let build = info["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}
