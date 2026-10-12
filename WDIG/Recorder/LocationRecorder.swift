import CoreLocation
import Foundation
import os

/// The recorder: everything that touches Core Location happens through this actor. It
/// spends the battery budget on purpose: live updates only while moving, a short
/// hundred-metre warm phase after a stop so a false stop costs little, nothing at all
/// while the phone sits, and wake-ups iOS pays for (a geofence exit, a significant change).
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

    static let fenceIdentifier = "stop"
    static let flushCount = 20
    static let flushSeconds: Double = 60

    private let store: RecorderStore
    private let logger = Logger(subsystem: "com.jkulak.wdig", category: "recorder")
    private var settings: RecorderSettings
    private(set) var phase: Phase = .off
    private var deviceId: UUID?
    private var session: CLServiceSession?
    private var diagnosticsTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var warmTimer: Task<Void, Never>?
    private var monitor: CLMonitor?
    private var monitorTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var lastKept: Fix?
    private var recentKept: [Fix] = []
    private var speeds: [(at: Date, speed: Double)] = []
    private var reference: Coordinate?
    private var hasFence = false
    private var pending: [PointSample] = []
    private var power: PowerSnapshot = .unknown
    private var recentEvents: [RecorderEventRecord] = []

    init(store: RecorderStore, settings: RecorderSettings = .load()) {
        self.store = store
        self.settings = settings
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
        await MainActor.run {
            LocationBridges.shared.recorder = self
            LocationBridges.shared.background.startSignificantChanges()
        }
        let session = CLServiceSession(authorization: .always)
        self.session = session
        diagnosticsTask = Task { [weak self] in
            do {
                for try await diagnostic in session.diagnostics {
                    guard let self else { return }
                    if diagnostic.authorizationDenied || diagnostic.authorizationDeniedGlobally {
                        await self.note(.error("location authorization denied"))
                    } else if diagnostic.alwaysAuthorizationDenied {
                        await self.note(.error("always authorization denied, while-using only"))
                    } else if diagnostic.authorizationRestricted {
                        await self.note(.error("location restricted"))
                    }
                }
            } catch {
                await self?.note(.error("session diagnostics: \(error.localizedDescription)"))
            }
        }
        let monitor = await CLMonitor("WDIGRecorder")
        self.monitor = monitor
        if await monitor.identifiers.contains(Self.fenceIdentifier) {
            await monitor.remove(Self.fenceIdentifier)
        }
        monitorTask = Task { [weak self] in
            do {
                for try await event in await monitor.events {
                    guard let self else { return }
                    await self.monitorEvent(identifier: event.identifier, state: event.state)
                }
            } catch {
                await self?.note(.error("monitor: \(error.localizedDescription)"))
            }
        }
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
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        monitorTask?.cancel()
        monitorTask = nil
        await removeFence()
        await MainActor.run {
            let bridges = LocationBridges.shared
            bridges.warm.stop()
            bridges.background.stopVisits()
            bridges.background.stopSignificantChanges()
        }
        session?.invalidate()
        session = nil
        monitor = nil
        phase = .off
        await flush()
        note(.stopped)
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

    func currentPhase() -> Phase {
        phase
    }

    func events() -> [RecorderEventRecord] {
        recentEvents
    }

    func note(_ event: RecorderEvent) {
        recentEvents.append(RecorderEventRecord(at: Date(), event: event))
        if recentEvents.count > 200 {
            recentEvents.removeFirst(recentEvents.count - 200)
        }
        logger.info("\(event.text, privacy: .public)")
    }

    // MARK: - Live updates

    private func startLive(_ kind: MovementKind) {
        liveTask?.cancel()
        phase = .live(kind)
        let configuration: CLLocationUpdate.LiveConfiguration = kind == .vehicle ? .otherNavigation : .fitness
        liveTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(configuration) {
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

    private func handle(_ update: CLLocationUpdate) async {
        guard case .live(let kind) = phase else { return }
        if update.authorizationDenied || update.authorizationDeniedGlobally {
            note(.error("live updates: authorization denied"))
            return
        }
        if update.stationary {
            note(.stationary)
            await beginWarmPhase(stationary: update.location.map(Fix.init))
            return
        }
        guard let location = update.location else { return }
        let fix = Fix(location)
        let now = fix.timestamp
        speeds.append((at: now, speed: fix.speed))
        speeds.removeAll { now.timeIntervalSince($0.at) > settings.classHoldSeconds * 2 }
        await keep(fix, kind: kind, source: "phone", coarse: false)
        let next = LiveKindPolicy.kind(current: kind, speeds: speeds, now: now, holdSeconds: settings.classHoldSeconds)
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
        await MainActor.run { LocationBridges.shared.warm.start() }
        let seconds = settings.warmPhaseSeconds
        warmTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
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
        await MainActor.run { LocationBridges.shared.warm.stop() }
        phase = .asleep
        if let reference, let monitor {
            let center = CLLocationCoordinate2D(latitude: reference.latitude, longitude: reference.longitude)
            let condition = CLMonitor.CircularGeographicCondition(center: center, radius: settings.fenceRadiusM)
            await monitor.add(condition, identifier: Self.fenceIdentifier, assuming: .satisfied)
            hasFence = true
        }
        note(.warmPhaseEnded)
        await flush()
    }

    private func monitorEvent(identifier: String, state: CLMonitor.Event.State) async {
        guard identifier == Self.fenceIdentifier, state == .unsatisfied, phase == .asleep else { return }
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
        await MainActor.run { LocationBridges.shared.warm.stop() }
        await removeFence()
        note(.resumed(trigger: trigger))
        startLive(.foot)
    }

    private func removeFence() async {
        guard hasFence, let monitor else { return }
        await monitor.remove(Self.fenceIdentifier)
        hasFence = false
    }

    // MARK: - Coarse mode

    private func enterCoarse(reason: String) async {
        liveTask?.cancel()
        liveTask = nil
        warmTimer?.cancel()
        warmTimer = nil
        await MainActor.run { LocationBridges.shared.warm.stop() }
        await removeFence()
        phase = .coarse
        await MainActor.run { LocationBridges.shared.background.startVisits() }
        note(.coarseModeEntered(reason: reason))
        await flush()
    }

    private func leaveCoarse() async {
        await MainActor.run { LocationBridges.shared.background.stopVisits() }
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
        pending.append(
            fix.sample(
                deviceId: deviceId, source: source, coarse: coarse, power: power, tz: TimeZone.current.identifier))
        if pending.count >= Self.flushCount {
            await flush()
        } else if flushTask == nil {
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.flushSeconds))
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
