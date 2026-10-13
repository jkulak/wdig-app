import UIKit

/// The one place the launch is seen before any view exists. A relaunch by Core
/// Location arrives here with the app in the background, and the recorder resumes
/// inside this launch rather than on the next tap.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let trigger = LaunchTrigger.from(applicationState: application.applicationState)
        LaunchTrigger.current = trigger
        RecorderHub.shared.launched(trigger: trigger)
        GPXDayExporter.cleanUp()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        RecorderHub.shared.willTerminate()
    }
}
