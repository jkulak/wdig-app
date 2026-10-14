import Foundation

/// What the recorder did, for the diagnostics log and the status screen.
enum RecorderEvent: Sendable, Equatable {
    case started(trigger: ResumeTrigger)
    case stopped
    case stationary
    case warmPhaseBegan
    case warmPhaseEnded
    case resumed(trigger: ResumeTrigger)
    case configurationChanged(from: MovementKind, to: MovementKind)
    case coarseModeEntered(reason: String)
    case coarseModeLeft
    case authorizationChanged(String)
    case activityUpdatesStarted
    case activityUpdatesStopped
    case activityBackfilled(from: Date, to: Date, count: Int)
    case stepsQueried(steps: Int?)
    case error(String)

    var text: String {
        switch self {
        case .started(let trigger): "started (\(trigger))"
        case .stopped: "stopped"
        case .stationary: "stationary"
        case .warmPhaseBegan: "warm phase began"
        case .warmPhaseEnded: "warm phase ended, fence set"
        case .resumed(let trigger): "resumed (\(trigger))"
        case .configurationChanged(let from, let to): "configuration \(from) -> \(to)"
        case .coarseModeEntered(let reason): "coarse mode entered (\(reason))"
        case .coarseModeLeft: "coarse mode left"
        case .authorizationChanged(let status): "authorization \(status)"
        case .activityUpdatesStarted: "activity updates started"
        case .activityUpdatesStopped: "activity updates stopped"
        case .activityBackfilled(let from, let to, let count):
            "backfill \(Self.minute(from))–\(Self.minute(to)), \(count) points"
        case .stepsQueried(let steps): "pedometer: \(steps.map(String.init) ?? "no") steps"
        case .error(let message): "error: \(message)"
        }
    }

    /// A moment in UTC to the minute, `2026-10-12T06:00Z`: the log is read next to the server's
    /// times, and a back-fill's range is never finer than that.
    private static func minute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm'Z'"
        return formatter.string(from: date)
    }
}

enum ResumeTrigger: String, Sendable {
    case user
    case motion
    case fenceExit
    case significantChange
    case foreground
    case launch
}

/// An event with the moment it happened.
struct RecorderEventRecord: Sendable, Equatable, Identifiable {
    var id: UUID = .v7()
    var at: Date
    var event: RecorderEvent
}
