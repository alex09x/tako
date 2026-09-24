import Foundation
import Testing
@testable import Tako

@Suite
struct AppReloadTests {
    @Test
    func reloadConfigPublishesTheNewGlobalConfiguration() {
        final class Received: @unchecked Sendable {
            var config: Tako.Config?
        }

        let app = Tako.App()
        let original = app.config
        let received = Received()
        let token = NotificationCenter.default.addObserver(
            forName: .takoConfigDidChange,
            object: nil,
            queue: nil
        ) { notification in
            received.config = notification.userInfo?[
                Notification.Name.TakoConfigChangeKey
            ] as? Tako.Config
        }
        defer { NotificationCenter.default.removeObserver(token) }

        app.reloadConfig()

        #expect(app.config !== original)
        #expect(received.config === app.config)
    }

    @Test
    func ptyAdvertisesItsOwnTerminalIdentity() {
        let environment = Dictionary(
            uniqueKeysWithValues: TakoPTYEnvironment.terminalIdentity(appVersion: "1.2.3"))

        // The app names itself truthfully; truecolor is advertised through
        // COLORTERM, not by borrowing upstream's TERM_PROGRAM.
        #expect(environment["TERM_PROGRAM"] == "tako")
        #expect(environment["TERM_PROGRAM_VERSION"] == "1.2.3")
    }

    @Test
    func ptyUsesStableFallbackVersion() {
        let environment = Dictionary(
            uniqueKeysWithValues: TakoPTYEnvironment.terminalIdentity(appVersion: nil))

        #expect(environment["TERM_PROGRAM_VERSION"] == "0.0.0")
    }

    @Test
    func ptyDoesNotLeakLauncherNoColorPreference() {
        #expect(TakoPTYEnvironment.variablesRemovedFromChild.contains("NO_COLOR"))
    }
}
