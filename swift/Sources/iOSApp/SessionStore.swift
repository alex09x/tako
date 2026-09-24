import Foundation
import SwiftUI

/// Every session the app knows about, plus the hosts it has trusted.
@MainActor
final class SessionStore: ObservableObject {
    @Published private(set) var sessions: [Session] = []
    @Published private(set) var recents: [SshDraft] = []

    private let defaults = UserDefaults.standard
    private let recentsKey = "tako.recents"

    init() {
        if LaunchOptions.resetsState {
            defaults.removeObject(forKey: recentsKey)
            KnownHosts.reset()
        }
        loadRecents()
        // The hosts you have reached come back as cards.
        //
        // A session itself cannot survive the process -- a shell on the far
        // end does not wait -- but the list is the thing you opened the app
        // for, and rebuilding it only as a single demo row read as the saved
        // sessions having been lost. They were never lost; they were two taps
        // deep inside the new-session sheet, which is the same thing from
        // where the user is standing.
        sessions = recents.map(Self.saved(from:))
        if sessions.isEmpty {
            // Never an empty screen with a button.
            let demo = Session(
                kind: .local,
                title: "local · demo",
                subtitle: "interactive · type help",
                status: .connected
            )
            demo.seedDemo()
            sessions = [demo]
        }
    }

    /// A host from a previous launch, with no way to authenticate yet: the
    /// app keeps where you went, never what got you in.
    private static func saved(from draft: SshDraft) -> Session {
        Session(
            kind: .ssh(Session.SshTarget(
                host: draft.host,
                port: UInt16(draft.port) ?? 22,
                username: draft.username,
                privateKeyPEM: nil,
                passphrase: nil,
                password: nil
            )),
            title: "\(draft.host) · ssh",
            subtitle: draft.subtitle,
            status: .disconnected(since: "saved")
        )
    }

    func addLocal() -> Session {
        let session = Session(
            kind: .local,
            title: "local · demo",
            subtitle: "interactive · type help",
            status: .connected
        )
        session.seedDemo()
        sessions.append(session)
        return session
    }

    /// Turns a finished form into a live session, and remembers the host.
    func add(from draft: SshDraft) -> Session {
        let target = Session.SshTarget(
            host: draft.host,
            port: UInt16(draft.port) ?? 22,
            username: draft.username,
            privateKeyPEM: draft.usesKey && !draft.privateKeyPEM.isEmpty
                ? draft.privateKeyPEM
                : nil,
            passphrase: draft.usesKey && !draft.passphrase.isEmpty
                ? draft.passphrase
                : nil,
            password: draft.usesKey ? nil : draft.password
        )
        let session = Session(
            kind: .ssh(target),
            title: "\(draft.host) · ssh",
            subtitle: draft.subtitle,
            status: .disconnected(since: "—")
        )
        // Replaces the saved card for the same host rather than sitting
        // beside it, which would leave the list showing one host twice the
        // first time you connected to it after a launch.
        if let existing = sessions.firstIndex(where: { matches($0, draft) }) {
            sessions[existing].disconnect()
            sessions[existing] = session
        } else {
            sessions.append(session)
        }
        remember(draft)
        return session
    }

    func remove(_ session: Session) {
        session.disconnect()
        sessions.removeAll { $0 === session }
        // Forgotten for good, or it comes back by itself on the next launch.
        if let draft = session.draft {
            recents.removeAll { Self.sameEndpoint($0, draft) }
            saveRecents()
        }
    }

    private func matches(_ session: Session, _ draft: SshDraft) -> Bool {
        guard let saved = session.draft else { return false }
        return Self.sameEndpoint(saved, draft)
    }

    private static func sameEndpoint(_ lhs: SshDraft, _ rhs: SshDraft) -> Bool {
        lhs.host == rhs.host
            && lhs.username == rhs.username
            && (UInt16(lhs.port) ?? 22) == (UInt16(rhs.port) ?? 22)
    }

    func reconnect(_ session: Session) {
        session.disconnect()
        session.connect()
    }

    // MARK: - Recents

    private func remember(_ draft: SshDraft) {
        // A secret is not a recent. Only enough to fill the form in again.
        var entry = draft
        entry.privateKeyPEM = ""
        entry.passphrase = ""
        entry.password = ""
        recents.removeAll { Self.sameEndpoint($0, entry) }
        recents.insert(entry, at: 0)
        recents = Array(recents.prefix(8))
        saveRecents()
    }

    private func loadRecents() {
        guard let raw = defaults.array(forKey: recentsKey) as? [[String: String]] else { return }
        recents = raw.compactMap { item in
            guard let host = item["host"], let user = item["user"] else { return nil }
            var draft = SshDraft()
            draft.host = host
            draft.username = user
            draft.port = item["port"] ?? "22"
            return draft
        }
    }

    private func saveRecents() {
        let raw = recents.map { ["host": $0.host, "user": $0.username, "port": $0.port] }
        defaults.set(raw, forKey: recentsKey)
    }
}

/// Trusted host keys, and the one-shot probe that fetches a new one.
///
/// The transport asks about a host key from its own thread and waits for the
/// answer before it sends anything -- which is right, and means the answer
/// cannot be a screen. So an unknown host is met with a probe that refuses
/// every key on purpose, purely to learn the fingerprint; the user is shown
/// it at leisure, and only then does the real connection go out. Two
/// handshakes, once per host, in exchange for never sending a credential to
/// something nobody looked at.
@MainActor
enum KnownHosts {
    /// Not private: the store clears it when a run asks to start clean.
    static let defaultsKey = "tako.knownHosts"
    private static var cached: [String: String]?

    /// Preferences are persistence, not live state. Re-reading the daemon on
    /// every lookup lets a late flush from an older Simulator process undo a
    /// reset in the process that is actually on screen.
    private static var all: [String: String] {
        get {
            if let cached { return cached }
            let loaded = (UserDefaults.standard.dictionary(forKey: defaultsKey)
                          as? [String: String]) ?? [:]
            cached = loaded
            return loaded
        }
        set {
            cached = newValue
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
        }
    }

    /// Test launches must begin with no implicit trust. Writing an empty
    /// value is deliberate: removing the key left a cached dictionary alive
    /// in Simulator's preferences daemon, so a supposedly fresh run could
    /// silently skip the host-key screen it existed to verify.
    static func reset() {
        all = [:]
    }

    private static func endpointKey(host: String, port: UInt16) -> String {
        port == 22 ? host : "[\(host)]:\(port)"
    }

    static func fingerprint(for host: String, port: UInt16) -> String? {
        all[endpointKey(host: host, port: port)]
    }

    static func trust(host: String, port: UInt16, fingerprint: String) {
        var values = all
        values[endpointKey(host: host, port: port)] = fingerprint
        all = values
    }

    static func forget(host: String, port: UInt16) {
        var values = all
        values[endpointKey(host: host, port: port)] = nil
        all = values
    }

    /// How a probe ended.
    enum ProbeOutcome {
        case presented(Presented)
        case failed(String)
    }

    /// What a probe found.
    struct Presented {
        let algorithm: String
        let fingerprint: String
        /// True when we have seen this host before and the key is different,
        /// which is the case that must never be a routine tap-through.
        let changed: Bool
    }

    /// Opens a connection far enough to see the host key, refuses it, and
    /// reports what it saw. Never authenticates, so no secret is at risk.
    static func probe(host: String, port: UInt16, username: String) async -> ProbeOutcome {
        // Read here, on the main actor, and hand the value down. The
        // transport's callbacks arrive on its own thread, and reaching back
        // for main-actor state from there is not a race to be got away with
        // -- `assumeIsolated` traps outright, which crashed the app on every
        // first connection to a new host.
        let known = fingerprint(for: host, port: port)
        return await withCheckedContinuation { continuation in
            let collector = ProbeEvents(host: host, known: known) { result in
                continuation.resume(returning: result)
            }
            _ = SshSession.connect(
                config: SshConfig(
                    host: host,
                    port: port,
                    username: username,
                    // Never sent: the probe refuses the key first.
                    auth: .password(password: ""),
                    term: "xterm-256color",
                    cols: 80,
                    rows: 24
                ),
                events: collector
            )
        }
    }
}

/// Collects the host key, refuses it, and answers exactly once.
private final class ProbeEvents: SshEvents, @unchecked Sendable {
    private let host: String
    /// The fingerprint already trusted for this host, captured before the
    /// probe started so no callback has to reach for main-actor state.
    private let known: String?
    private let finish: (KnownHosts.ProbeOutcome) -> Void
    private var seen: (String, String)?
    private var answered = false
    private let lock = NSLock()

    init(host: String, known: String?, finish: @escaping (KnownHosts.ProbeOutcome) -> Void) {
        self.host = host
        self.known = known
        self.finish = finish
    }

    func onHostKey(algorithm: String, fingerprint: String) -> Bool {
        lock.withLock { seen = (algorithm, fingerprint) }
        // Refusing is the point: this connection exists only to look.
        return false
    }

    func onConnected() {}
    func onKeyboardInteractive(
        challengeId: UInt64,
        name: String,
        instructions: String,
        prompts: [SshPrompt]
    ) {
        // A probe refuses the host key before authentication, so this is
        // unreachable. Keep the callback inert rather than manufacturing an
        // answer if a broken server sends messages out of order.
    }
    func onData(data: Data) {}

    func onClosed(reason: String) {
        let payload: KnownHosts.ProbeOutcome = lock.withLock {
            guard !answered else { return .failed("") }
            answered = true
            guard let (algorithm, fingerprint) = seen else {
                return .failed(reason.isEmpty ? "the host did not answer" : reason)
            }
            return .presented(
                .init(
                    algorithm: algorithm,
                    fingerprint: fingerprint,
                    changed: known != nil && known != fingerprint
                )
            )
        }
        if case .failed(let message) = payload, message.isEmpty { return }
        finish(payload)
    }
}
