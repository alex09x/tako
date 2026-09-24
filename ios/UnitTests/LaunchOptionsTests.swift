import Foundation
import XCTest
@testable import TakoCore

/// Every `-tako*` flag `LaunchOptions` parses, driven through the injectable
/// `LaunchOptions.arguments` rather than a real process relaunch -- a
/// hosted unit test shares its process with the app under test, so
/// `CommandLine.arguments` is fixed for the whole run and cannot vary
/// per test case.
final class LaunchOptionsTests: XCTestCase {
    private let originalArguments = LaunchOptions.arguments

    override func tearDown() {
        LaunchOptions.arguments = originalArguments
        super.tearDown()
    }

    private func set(_ args: [String]) {
        LaunchOptions.arguments = ["TakoCore"] + args
    }

    // MARK: - -takoScreen

    func testScreenParsesEveryCase() {
        for (raw, expected) in [("sheet", LaunchOptions.Screen.sheet),
                                 ("form", .form),
                                 ("terminal", .terminal)] {
            set(["-takoScreen", raw])
            XCTAssertEqual(LaunchOptions.screen, expected)
        }
    }

    func testScreenMissingIsNil() {
        set([])
        XCTAssertNil(LaunchOptions.screen)
    }

    func testScreenInvalidValueIsNil() {
        set(["-takoScreen", "bogus"])
        XCTAssertNil(LaunchOptions.screen)
    }

    func testScreenFlagWithNoValueIsNil() {
        set(["-takoScreen"])
        XCTAssertNil(LaunchOptions.screen)
    }

    // MARK: - -takoHost / -takoKeyPath / -takoPassphrasePath / -takoPasswordPath

    func testHostParsesHostPortUser() {
        set(["-takoHost", "127.0.0.1:2223:alex09x"])
        let draft = LaunchOptions.host
        XCTAssertEqual(draft?.host, "127.0.0.1")
        XCTAssertEqual(draft?.port, "2223")
        XCTAssertEqual(draft?.username, "alex09x")
        XCTAssertEqual(draft?.privateKeyPEM, "")
        XCTAssertEqual(draft?.password, "")
    }

    func testHostMissingIsNil() {
        set([])
        XCTAssertNil(LaunchOptions.host)
    }

    func testHostTooFewPartsIsNil() {
        set(["-takoHost", "127.0.0.1:2223"])
        XCTAssertNil(LaunchOptions.host)
    }

    func testHostExtraColonsFoldIntoUsername() {
        // maxSplits: 2, so a colon inside the username's own text -- an
        // unusual but not impossible one -- stays in the third field rather
        // than being rejected.
        set(["-takoHost", "127.0.0.1:2223:al:ex"])
        XCTAssertEqual(LaunchOptions.host?.username, "al:ex")
    }

    func testHostWithKeyPathAbsolute() throws {
        let path = NSTemporaryDirectory() + "tako-unit-test-key-\(UUID().uuidString).pem"
        try "-----BEGIN KEY-----\ntest\n-----END KEY-----".write(
            toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        set(["-takoHost", "h:22:u", "-takoKeyPath", path])
        let draft = LaunchOptions.host
        XCTAssertEqual(draft?.usesKey, true)
        XCTAssertTrue(draft?.privateKeyPEM.contains("BEGIN KEY") ?? false)
    }

    func testHostWithKeyPathRelativeReadsFromDocuments() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = "tako-unit-test-key-\(UUID().uuidString).pem"
        try "relative-key-contents".write(
            to: docs.appendingPathComponent(name), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: docs.appendingPathComponent(name)) }

        set(["-takoHost", "h:22:u", "-takoKeyPath", name])
        XCTAssertEqual(LaunchOptions.host?.privateKeyPEM, "relative-key-contents")
        XCTAssertEqual(LaunchOptions.host?.usesKey, true)
    }

    func testHostWithMissingKeyPathLeavesNoKey() {
        set(["-takoHost", "h:22:u", "-takoKeyPath", "/no/such/file-\(UUID().uuidString)"])
        XCTAssertEqual(LaunchOptions.host?.privateKeyPEM, "")
        XCTAssertEqual(LaunchOptions.host?.usesKey, true) // default from SshDraft()
    }

    func testHostWithPassphrasePathTrimsNewlines() throws {
        let path = NSTemporaryDirectory() + "tako-unit-test-pass-\(UUID().uuidString)"
        try "s3cret\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        set(["-takoHost", "h:22:u", "-takoPassphrasePath", path])
        XCTAssertEqual(LaunchOptions.host?.passphrase, "s3cret")
    }

    func testHostWithPasswordPathTrimsNewlinesAndClearsUsesKey() throws {
        let path = NSTemporaryDirectory() + "tako-unit-test-pwd-\(UUID().uuidString)"
        try "hunter2\r\n".write(toFile: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: path) }

        set(["-takoHost", "h:22:u", "-takoPasswordPath", path])
        let draft = LaunchOptions.host
        XCTAssertEqual(draft?.password, "hunter2")
        XCTAssertEqual(draft?.usesKey, false)
    }

    func testHostWithBothKeyAndPasswordPathsPasswordWins() throws {
        // The password branch runs last in `LaunchOptions.host` and always
        // clears `usesKey`, even when a key was also supplied -- so a launch
        // script that (by mistake) passes both ends up authenticating with
        // the password, not silently with whichever came first.
        let keyPath = NSTemporaryDirectory() + "tako-unit-test-key2-\(UUID().uuidString)"
        let pwdPath = NSTemporaryDirectory() + "tako-unit-test-pwd2-\(UUID().uuidString)"
        try "key-data".write(toFile: keyPath, atomically: true, encoding: .utf8)
        try "pwd-data".write(toFile: pwdPath, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: keyPath)
            try? FileManager.default.removeItem(atPath: pwdPath)
        }

        set(["-takoHost", "h:22:u", "-takoKeyPath", keyPath, "-takoPasswordPath", pwdPath])
        let draft = LaunchOptions.host
        XCTAssertEqual(draft?.privateKeyPEM, "key-data")
        XCTAssertEqual(draft?.password, "pwd-data")
        XCTAssertEqual(draft?.usesKey, false)
    }

    // MARK: - -takoResetState

    func testResetsStatePresent() {
        set(["-takoResetState"])
        XCTAssertTrue(LaunchOptions.resetsState)
    }

    func testResetsStateAbsent() {
        set([])
        XCTAssertFalse(LaunchOptions.resetsState)
    }

    // MARK: - -takoTrustHostKey

    func testTrustsAnyHostKeyPresent() {
        set(["-takoTrustHostKey"])
        XCTAssertTrue(LaunchOptions.trustsAnyHostKey)
    }

    func testTrustsAnyHostKeyAbsent() {
        set([])
        XCTAssertFalse(LaunchOptions.trustsAnyHostKey)
    }

    // MARK: - -takoCredentialResource (testCredentialSeed)

    func testCredentialSeedMissingArgIsNil() {
        set([])
        XCTAssertNil(LaunchOptions.testCredentialSeed)
    }

    func testCredentialSeedRejectsPathSeparators() {
        set(["-takoCredentialResource", "sub/dir/name"])
        XCTAssertNil(LaunchOptions.testCredentialSeed)
    }

    func testCredentialSeedMissingResourceIsNil() {
        set(["-takoCredentialResource", "no-such-bundled-resource-\(UUID().uuidString)"])
        XCTAssertNil(LaunchOptions.testCredentialSeed)
    }

    // MARK: - -takoKnownHost / -takoKnownPort / -takoKnownFingerprint

    func testKnownHostSeedValid() {
        set(["-takoKnownHost", "example.com", "-takoKnownPort", "22",
             "-takoKnownFingerprint", "SHA256:abc"])
        let seed = LaunchOptions.testKnownHostSeed
        XCTAssertEqual(seed?.host, "example.com")
        XCTAssertEqual(seed?.port, 22)
        XCTAssertEqual(seed?.fingerprint, "SHA256:abc")
    }

    func testKnownHostSeedMissingHostIsNil() {
        set(["-takoKnownPort", "22", "-takoKnownFingerprint", "SHA256:abc"])
        XCTAssertNil(LaunchOptions.testKnownHostSeed)
    }

    func testKnownHostSeedInvalidPortIsNil() {
        set(["-takoKnownHost", "example.com", "-takoKnownPort", "not-a-port",
             "-takoKnownFingerprint", "SHA256:abc"])
        XCTAssertNil(LaunchOptions.testKnownHostSeed)
    }

    func testKnownHostSeedEmptyHostIsNil() {
        set(["-takoKnownHost", "", "-takoKnownPort", "22",
             "-takoKnownFingerprint", "SHA256:abc"])
        XCTAssertNil(LaunchOptions.testKnownHostSeed)
    }

    func testKnownHostSeedEmptyFingerprintIsNil() {
        set(["-takoKnownHost", "example.com", "-takoKnownPort", "22",
             "-takoKnownFingerprint", ""])
        XCTAssertNil(LaunchOptions.testKnownHostSeed)
    }

    func testKnownHostSeedMissingFingerprintIsNil() {
        set(["-takoKnownHost", "example.com", "-takoKnownPort", "22"])
        XCTAssertNil(LaunchOptions.testKnownHostSeed)
    }

    // MARK: - -takoSend (step splitting and escapes)

    func testSendStepsMissingIsEmpty() {
        set([])
        XCTAssertEqual(LaunchOptions.sendSteps, [])
    }

    func testSendStepsSplitsOnBackslashP() {
        set(["-takoSend", "hello\\pworld"])
        XCTAssertEqual(LaunchOptions.sendSteps, ["hello", "world"])
    }

    func testSendStepsUnescapesNewlineTabAndHexByte() {
        set(["-takoSend", "a\\nb\\tc\\x41"])
        XCTAssertEqual(LaunchOptions.sendSteps, ["a\nb\tc\u{41}"])
    }

    func testSendStepsInvalidHexEscapePassesThrough() {
        set(["-takoSend", "a\\xZZb"])
        XCTAssertEqual(LaunchOptions.sendSteps, ["a\\xZZb"])
    }

    func testSendStepsTruncatedHexEscapePassesThrough() {
        set(["-takoSend", "a\\x4"])
        XCTAssertEqual(LaunchOptions.sendSteps, ["a\\x4"])
    }

    func testSendStepsSignedHexEscapePassesThrough() {
        set(["-takoSend", "a\\x+4b"])
        XCTAssertEqual(LaunchOptions.sendSteps, ["a\\x+4b"])
    }

    func testSendStepsTrailingBackslashIsKept() {
        set(["-takoSend", "abc\\"])
        XCTAssertEqual(LaunchOptions.sendSteps, ["abc\\"])
    }

    func testSendStepsUnknownEscapeKeepsLetter() {
        // `\z` has no case in `unescape`, so the default branch drops only
        // the backslash and keeps `z` itself.
        set(["-takoSend", "a\\zb"])
        XCTAssertEqual(LaunchOptions.sendSteps, ["azb"])
    }

    func testSendStepsPreservesKeyRowStepVerbatim() {
        set(["-takoSend", "tail -f log\\n\\p@ctrl+c\\pecho done\\n"])
        XCTAssertEqual(LaunchOptions.sendSteps, ["tail -f log\n", "@ctrl+c", "echo done\n"])
    }

    // MARK: - -takoDump

    func testDumpAfterValid() {
        set(["-takoDump", "8"])
        XCTAssertEqual(LaunchOptions.dumpAfter, 8.0)
    }

    func testDumpAfterFractional() {
        set(["-takoDump", "0.25"])
        XCTAssertEqual(LaunchOptions.dumpAfter, 0.25)
    }

    func testDumpAfterMissingIsNil() {
        set([])
        XCTAssertNil(LaunchOptions.dumpAfter)
    }

    func testDumpAfterInvalidIsNil() {
        set(["-takoDump", "not-a-number"])
        XCTAssertNil(LaunchOptions.dumpAfter)
    }
}
