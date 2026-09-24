import Foundation

/// Launch arguments that put the app on a given screen, so a screen can be
/// looked at without a finger.
///
/// A simulator can be booted, installed to and screenshotted from a script,
/// but it cannot be tapped -- `simctl` has no such verb. Without a way in,
/// every screen past the first is unverifiable except by hand, which means
/// in practice unverified. ProdMobile solved the same problem with
/// `PROD_TEST_MODE`; this is the small version of that.
///
/// Nothing here is reachable without an explicit argument, so a shipped build
/// behaves as though the file were not there.
enum LaunchOptions {
    /// The process's own launch arguments, save for unit tests: they cannot
    /// relaunch the host app per case, so they overwrite this to exercise
    /// every parse path against arguments of their own choosing.
    static var arguments: [String] = CommandLine.arguments

    /// `-takoScreen sheet|form|terminal`
    enum Screen: String {
        case sheet
        case form
        case terminal
    }

    static var screen: Screen? {
        value(for: "-takoScreen").flatMap(Screen.init(rawValue:))
    }

    /// `-takoHost 127.0.0.1:2223:alex09x` — host, port, user for a session
    /// the app opens on launch. The key comes from `-takoKeyPath`, because a
    /// private key does not belong in a process argument list.
    static var host: SshDraft? {
        guard let raw = value(for: "-takoHost") else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3 else { return nil }

        var draft = SshDraft()
        draft.host = parts[0]
        draft.port = parts[1]
        draft.username = parts[2]
        if let path = value(for: "-takoKeyPath").map(resolved(path:)),
           let pem = try? String(contentsOfFile: path, encoding: .utf8) {
            draft.privateKeyPEM = pem
            draft.usesKey = true
        }
        if let path = value(for: "-takoPassphrasePath").map(resolved(path:)),
           let secret = try? String(contentsOfFile: path, encoding: .utf8) {
            draft.passphrase = secret.trimmingCharacters(in: .newlines)
        }
        // From a file for the same reason as the key: a password on a command
        // line is readable by every other process on the machine, and a habit
        // formed in a test is a habit.
        if let path = value(for: "-takoPasswordPath").map(resolved(path:)),
           let secret = try? String(contentsOfFile: path, encoding: .utf8) {
            draft.password = secret.trimmingCharacters(in: .newlines)
            draft.usesKey = false
        }
        return draft
    }

    /// `-takoResetState` forgets every remembered host and trusted key at
    /// launch.
    ///
    /// A walkthrough that trusts a host leaves it trusted, so the next run
    /// skips the prompt it exists to check -- the test passes once and then
    /// stops testing anything. Cheaper than reinstalling the app between
    /// runs, and it clears exactly the two keys rather than the container.
    static var resetsState: Bool {
        arguments.contains("-takoResetState")
    }

    /// A generated credential bundled only into Debug UI-test builds. The
    /// visible Paste button still owns the state transition; this replaces
    /// only Simulator's cross-process paste-permission service, which XCTest
    /// cannot drive reliably. Release builds always return nil.
    static var testCredentialSeed: String? {
#if DEBUG
        guard let name = value(for: "-takoCredentialResource"),
              !name.contains("/"),
              let url = Bundle.main.url(forResource: name, withExtension: nil)
        else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
#else
        return nil
#endif
    }

    /// A deliberately stale host-key entry for the changed-key UI test.
    /// This cannot be enabled in Release and carries no credential: it only
    /// lets XCTest reproduce a server-key mismatch without rewriting the
    /// disposable sshd while another UI test may be connected to it.
    static var testKnownHostSeed: (host: String, port: UInt16, fingerprint: String)? {
#if DEBUG
        guard let host = value(for: "-takoKnownHost"),
              let portText = value(for: "-takoKnownPort"),
              let port = UInt16(portText),
              let fingerprint = value(for: "-takoKnownFingerprint"),
              !host.isEmpty,
              !fingerprint.isEmpty
        else { return nil }
        return (host, port, fingerprint)
#else
        return nil
#endif
    }

    /// `-takoTrustHostKey` accepts the first host key without asking, which
    /// is exactly what a screenshot run needs and exactly what a real one
    /// must not do.
    static var trustsAnyHostKey: Bool {
        arguments.contains("-takoTrustHostKey")
    }

    /// `-takoSend 'tail -f log\n\p\x03\pecho done\n'` — typed into the session
    /// once it connects, so a scripted run can do something rather than just
    /// arrive.
    ///
    /// `\n`, `\t` and `\xNN` are spelled out because an argument list is a
    /// poor place to carry a control byte, and `\p` splits the input into
    /// steps sent a beat apart -- which is the only way to script the cases
    /// that are about a *sequence*, like interrupting a running program.
    ///
    /// A step beginning `@` is a key-row press rather than typed text:
    /// `@ctrl+c` arms ⌃ and then presses `c`, the way a thumb would. Plain
    /// text goes through the software keyboard's own entry point. Both take
    /// the app's real input path; see ``LaunchProbe``.
    static var sendSteps: [String] {
        guard let raw = value(for: "-takoSend") else { return [] }
        return raw.components(separatedBy: "\\p").map(unescape(_:))
    }

    private static func unescape(_ s: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let slash = rest.firstIndex(of: "\\") {
            out += rest[rest.startIndex..<slash]
            let after = rest.index(after: slash)
            guard after < rest.endIndex else { out += "\\"; return out }
            switch rest[after] {
            case "n": out += "\n"; rest = rest[rest.index(after: after)...]
            case "t": out += "\t"; rest = rest[rest.index(after: after)...]
            case "x":
                // Exactly two hex digits, or the escape is kept as typed:
                // `UInt8(_:radix:)` alone would take "4" at the end of the
                // string, or "+4" anywhere.
                let start = rest.index(after: after)
                if let end = rest.index(start, offsetBy: 2, limitedBy: rest.endIndex),
                   rest[start..<end].allSatisfy(\.isHexDigit),
                   let byte = UInt8(rest[start..<end], radix: 16) {
                    out.append(Character(UnicodeScalar(byte)))
                    rest = rest[end...]
                } else {
                    out += "\\x"; rest = start < rest.endIndex ? rest[start...] : ""
                }
            default: out.append(rest[after]); rest = rest[rest.index(after: after)...]
            }
        }
        return out + rest
    }

    /// `-takoDump 8` — seconds to wait before writing what the terminal holds
    /// into the app's Documents directory. See ``LaunchProbe``.
    static var dumpAfter: TimeInterval? {
        value(for: "-takoDump").flatMap(TimeInterval.init)
    }

    /// A relative path means "inside this app's Documents", which is where
    /// `devicectl device copy to` can put a file. An absolute one is left
    /// alone, for the simulator, where the Mac's own paths are readable.
    ///
    /// Worth the indirection because the container's absolute path carries a
    /// UUID that changes on every reinstall, so a caller that spelled it out
    /// would be passing a stale path one install later.
    private static func resolved(path: String) -> String {
        guard !path.hasPrefix("/") else { return path }
        let docs = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask
        ).first
        return docs?.appendingPathComponent(path).path ?? path
    }

    private static func value(for flag: String) -> String? {
        let args = arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
