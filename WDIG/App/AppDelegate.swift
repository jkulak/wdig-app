import UIKit

/// The one place the launch is seen before any view exists. A relaunch by Core
/// Location arrives here with the app in the background, and the recorder has to
/// know it so it resumes inside the launch rather than on the next tap.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        LaunchTrigger.current = LaunchTrigger.from(applicationState: application.applicationState)
        return true
    }
}
