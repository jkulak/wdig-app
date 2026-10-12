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
        case .error(let message): "error: \(message)"
        }
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
