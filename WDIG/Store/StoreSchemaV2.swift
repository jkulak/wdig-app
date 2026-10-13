import Foundation
import SwiftData

/// The second shape of the store: the first plus the diagnostics log. The first schema's
/// models are reused as they are, since none of them changed; only what is new is here.
enum StoreSchemaV2: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 0, 0)

    static var models: [any PersistentModel.Type] {
        StoreSchemaV1.models + [DiagnosticEvent.self]
    }

    /// One thing the recorder or the app did, with the phone's state at that moment. Never
    /// a position: the log may be pasted into an issue or sent to a tester.
    @Model
    final class DiagnosticEvent {
        #Unique<DiagnosticEvent>([\.id])
        #Index<DiagnosticEvent>([\.at], [\.localDay, \.at])

        var id: UUID
        var at: Date
        var tz: String
        var localDay: String
        var kind: String
        var detail: String
        var batteryPct: Int16?
        var batteryState: Int16?
        var lowPowerMode: Bool
        var thermalState: String
        var appState: String
        var build: String

        init(_ record: DiagnosticRecord) {
            id = record.id
            at = record.at
            tz = record.tz
            localDay = LocalDay.key(for: record.at, tz: record.tz)
            kind = record.kind
            detail = record.detail
            batteryPct = record.batteryPct
            batteryState = record.batteryState
            lowPowerMode = record.lowPowerMode
            thermalState = record.thermalState
            appState = record.appState
            build = record.build
        }
    }
}

typealias DiagnosticEvent = StoreSchemaV2.DiagnosticEvent

/// A logged event as a value; also the shape of one line of the export.
struct DiagnosticRecord: Sendable, Equatable, Identifiable, Codable {
    var id: UUID
    var at: Date
    var tz: String
    var kind: String
    var detail: String
    var batteryPct: Int16?
    var batteryState: Int16?
    var lowPowerMode: Bool
    var thermalState: String
    var appState: String
    var build: String

    init(_ event: DiagnosticEvent) {
        id = event.id
        at = event.at
        tz = event.tz
        kind = event.kind
        detail = event.detail
        batteryPct = event.batteryPct
        batteryState = event.batteryState
        lowPowerMode = event.lowPowerMode
        thermalState = event.thermalState
        appState = event.appState
        build = event.build
    }

    init(
        at: Date, tz: String, kind: String, detail: String = "", batteryPct: Int16? = nil, batteryState: Int16? = nil,
        lowPowerMode: Bool = false, thermalState: String = "nominal", appState: String = "active", build: String = ""
    ) {
        id = .v7(now: at)
        self.at = at
        self.tz = tz
        self.kind = kind
        self.detail = detail
        self.batteryPct = batteryPct
        self.batteryState = batteryState
        self.lowPowerMode = lowPowerMode
        self.thermalState = thermalState
        self.appState = appState
        self.build = build
    }
}
