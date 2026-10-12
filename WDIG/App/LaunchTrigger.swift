import UIKit

/// How the process started. A relaunch by Core Location (a significant-change or
/// geofence event after the system ended the process) starts the app in the
/// background with nobody in front of the phone; the diagnostics log records it and
/// the recorder resumes inside that launch. iOS 26 deprecated the location key of the
/// launch options, so the application state is the signal, and the recorder re-creates
/// its sessions at every launch regardless of the trigger.
enum LaunchTrigger: Equatable, Sendable {
    /// Opened by the user: the app is active or about to be.
    case foreground
    /// Started by the system in the background: Core Location or a background task.
    case background

    /// The trigger of the current process, set once by the app delegate.
    @MainActor static var current: LaunchTrigger = .foreground

    static func from(applicationState state: UIApplication.State) -> LaunchTrigger {
        state == .background ? .background : .foreground
    }
}
