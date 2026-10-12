import Testing
import UIKit

@testable import WDIG

struct LaunchTriggerTests {
    @Test("An app that starts active was opened by the user")
    func anAppThatStartsActiveWasOpenedByTheUser() {
        #expect(LaunchTrigger.from(applicationState: .active) == .foreground)
    }

    @Test("An app that starts inactive is on its way to the foreground")
    func anAppThatStartsInactiveIsOnItsWayToTheForeground() {
        #expect(LaunchTrigger.from(applicationState: .inactive) == .foreground)
    }

    @Test("An app that starts in the background was launched by the system")
    func anAppThatStartsInTheBackgroundWasLaunchedByTheSystem() {
        #expect(LaunchTrigger.from(applicationState: .background) == .background)
    }
}
