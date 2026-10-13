import Foundation
import UIKit

/// The diagnostics log: every recorder event and every launch, kill, gap and settings
/// change, kept thirty days in the store and exported as JSON Lines. Nothing in it is a
/// position.
@MainActor
final class DiagnosticsLog {
    nonisolated static let keptDays = 30
    nonisolated static let exportDays = 7
    nonisolated static let lastEventKey = "diagnostics.lastEvent"
    /// The kinds after which the previous run ended on purpose.
    nonisolated static let endsCleanly: Set<String> = ["stopped", "appWillTerminate"]
    /// The kinds after which the recorder is quiet on purpose: asleep behind a fence, in
    /// coarse mode, or off.
    nonisolated static let silentKinds: Set<String> = ["warmPhaseEnded", "coarseModeEntered", "stopped"]
    /// The kinds that are the recorder's own, which the gap detector counts as activity.
    nonisolated static let recorderKinds: Set<String> = [
        "started", "stopped", "stationary", "warmPhaseBegan", "warmPhaseEnded", "resumed", "configurationChanged",
        "coarseModeEntered", "coarseModeLeft", "authorizationChanged", "activityUpdatesStarted",
        "activityUpdatesStopped", "activityBackfilled", "stepsQueried", "error",
    ]

    /// The first line of an export.
    struct Header: Encodable {
        var device: String
        var ios: String
        var appVersion: String
        var build: String
        var settings: RecorderSettings
        var tz: String
        var lowPowerMode: Bool
    }

    private let store: RecorderStore
    private let defaults: UserDefaults

    init(store: RecorderStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }

    func log(_ kind: String, detail: String = "") async {
        let record = Self.record(kind: kind, detail: detail)
        remember(kind: kind, at: record.at)
        try? await store.logDiagnostic(record)
    }

    func log(_ event: RecorderEventRecord) async {
        await log(Self.kind(of: event.event), detail: event.event.text)
    }

    /// At launch: whether the previous run ended without saying so, then the launch itself,
    /// then the pruning.
    func launched(trigger: LaunchTrigger) async {
        if let killedAt = Self.previousRunKilled(lastKind: lastKind, lastAt: lastAt) {
            await log("previousRunKilled", detail: "lastEventAt \(XMLOut.time(killedAt))")
        }
        await log("appLaunched", detail: trigger == .background ? "location" : "user")
        let cutoff = Date().addingTimeInterval(-Double(Self.keptDays) * 86_400)
        _ = try? await store.pruneDiagnostics(olderThan: cutoff)
    }

    /// The marker is set at once: the store write may not finish in the seconds iOS gives.
    func willTerminate() {
        remember(kind: "appWillTerminate", at: Date())
        Task { await log("appWillTerminate") }
    }

    func events(onDay day: String) async -> [DiagnosticRecord] {
        (try? await store.diagnostics(onDay: day)) ?? []
    }

    /// The JSON Lines file for the stretch, in the temporary directory.
    func export(from: Date, to: Date) async throws -> URL {
        let events = try await store.diagnostics(from: from, to: to)
        let header = Header(
            device: DeviceInfo.model, ios: UIDevice.current.systemVersion, appVersion: DeviceInfo.appVersion,
            build: DeviceInfo.appVersion, settings: RecorderSettings.load(), tz: TimeZone.current.identifier,
            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        let text = try Self.render(header: header, events: events)
        let url = FileManager.default.temporaryDirectory.appending(
            path: Self.fileName(from: from, to: to, tz: TimeZone.current.identifier))
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - The pure parts

    nonisolated static func previousRunKilled(lastKind: String?, lastAt: Date?) -> Date? {
        guard let lastKind, let lastAt, !endsCleanly.contains(lastKind) else { return nil }
        return lastAt
    }

    /// A header line, then one event per line, each a JSON object with snake_case keys.
    nonisolated static func render(header: Header, events: [DiagnosticRecord]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var lines = [String(decoding: try encoder.encode(header), as: UTF8.self)]
        for event in events {
            lines.append(String(decoding: try encoder.encode(event), as: UTF8.self))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    nonisolated static func fileName(from: Date, to: Date, tz: String) -> String {
        "wdig-diagnostics-\(LocalDay.key(for: from, tz: tz))-\(LocalDay.key(for: to, tz: tz)).jsonl"
    }

    /// What changed between two settings, field by field, for the `settingsChanged` event.
    nonisolated static func changes(from old: RecorderSettings, to new: RecorderSettings) -> String {
        let before = Mirror(reflecting: old).children
        let after = Mirror(reflecting: new).children
        return zip(before, after).compactMap { was, now -> String? in
            let a = "\(was.value)"
            let b = "\(now.value)"
            guard a != b, let label = was.label else { return nil }
            return "\(label) \(a) -> \(b)"
        }.joined(separator: ", ")
    }

    nonisolated static func kind(of event: RecorderEvent) -> String {
        switch event {
        case .started: "started"
        case .stopped: "stopped"
        case .stationary: "stationary"
        case .warmPhaseBegan: "warmPhaseBegan"
        case .warmPhaseEnded: "warmPhaseEnded"
        case .resumed: "resumed"
        case .configurationChanged: "configurationChanged"
        case .coarseModeEntered: "coarseModeEntered"
        case .coarseModeLeft: "coarseModeLeft"
        case .authorizationChanged: "authorizationChanged"
        case .activityUpdatesStarted: "activityUpdatesStarted"
        case .activityUpdatesStopped: "activityUpdatesStopped"
        case .activityBackfilled: "activityBackfilled"
        case .stepsQueried: "stepsQueried"
        case .error: "error"
        }
    }

    // MARK: - The phone's state

    private static func record(kind: String, detail: String) -> DiagnosticRecord {
        let power = PowerObserver.current()
        return DiagnosticRecord(
            at: Date(), tz: TimeZone.current.identifier, kind: kind, detail: detail, batteryPct: power.levelPercent,
            batteryState: power.stateCode, lowPowerMode: power.lowPowerMode, thermalState: thermalState(),
            appState: appState(), build: DeviceInfo.appVersion)
    }

    private var lastKind: String? {
        defaults.dictionary(forKey: Self.lastEventKey)?["kind"] as? String
    }

    private var lastAt: Date? {
        (defaults.dictionary(forKey: Self.lastEventKey)?["at"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
    }

    private func remember(kind: String, at: Date) {
        defaults.set(["kind": kind, "at": at.timeIntervalSince1970] as [String: Any], forKey: Self.lastEventKey)
    }

    nonisolated static func thermalState() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }

    static func appState() -> String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}
