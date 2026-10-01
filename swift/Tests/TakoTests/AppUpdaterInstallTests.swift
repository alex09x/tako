import Foundation
import Testing
@testable import Tako

/// What the updater refuses. It replaces the running app with a downloaded
/// one, so it checks the download before anything else happens.
struct AppUpdaterInstallTests {
    @Test func onlyA404MeansNoRelease() throws {
        #expect(try AppUpdater.release(from: Data(), status: 404) == nil)
        for status in [403, 429, 500, 502] {
            #expect(throws: AppUpdater.UpdateError.self, "HTTP \(status) is a failed check, not up to date") {
                try AppUpdater.release(from: Data(), status: status)
            }
        }
        #expect(throws: AppUpdater.UpdateError.self) { try AppUpdater.release(from: Data(), status: nil) }
    }

    @Test func aBuildWithNoTeamNeverInstallsAnUpdate() {
        #expect(throws: AppUpdater.UpdateError.self) {
            try AppUpdater.verify(URL(fileURLWithPath: "/System/Applications/Calculator.app"), signedBy: nil)
        }
    }

    @Test func anAppFromAnotherDeveloperIsRefused() {
        // Calculator is Apple's, not this team's.
        #expect(throws: AppUpdater.UpdateError.self) {
            try AppUpdater.verify(URL(fileURLWithPath: "/System/Applications/Calculator.app"), signedBy: "ABCDE12345")
        }
    }

    @Test func somethingThatIsNotABundleIsRefused() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("not-an-app-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: AppUpdater.UpdateError.self) { try AppUpdater.verify(dir, signedBy: "ABCDE12345") }
    }

    @Test func aFailedToolIsAnError() {
        #expect(throws: AppUpdater.UpdateError.self) { try AppUpdater.run("/usr/bin/false", []) }
        #expect(throws: Never.self) { try AppUpdater.run("/usr/bin/true", []) }
    }

    @Test func anUnsignedBundleHasNoTeam() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("unsigned-\(UUID().uuidString).app")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(AppUpdater.teamIdentifier(of: dir) == nil)
    }
}
