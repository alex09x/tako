import Darwin
import Foundation

// session-persistence (experimental, off by default): a terminal's shell
// runs inside a zmx session, so it outlives Tako. This file holds the parts
// that decide, without touching any user process, what a terminal reattaches
// to: where sessions live, who owns one, what Tako recorded about it, and
// how an attach attempt is classified.

/// The private directory a runtime generation's sessions live in:
/// `~/.tako-sessions/<runtime id>/`, short enough for a Unix socket path (zmx
/// puts each session's socket at `<dir>/<name>`, and macOS allows 104 bytes).
/// The directory also records the runtime id it was made for; a directory
/// whose record says otherwise is refused, never shared.
struct SessionNamespace: Equatable {
    enum Failure: Error, Equatable {
        case notPrivate(String)
        case belongsToAnotherRuntime(String)
        case pathTooLong(Int)
    }

    /// macOS `sockaddr_un.sun_path` is 104 bytes, NUL included.
    static let socketPathLimit = 103

    let directory: URL
    let runtimeID: String

    /// The runtime id itself (version and 64 bits of its hash), already
    /// checked to be one plain path component by the registry.
    static func token(for runtimeID: String) throws -> String {
        guard SessionRuntimeRegistry.isValidID(runtimeID) else { throw Failure.notPrivate(runtimeID) }
        return runtimeID
    }

    /// The session name for a terminal: its id, 32 hex digits.
    static func sessionName(for id: UUID) -> String {
        id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Opens (creating if needed) the namespace for `runtimeID` under `home`,
    /// checking it is a real directory owned by this user and readable by no
    /// one else, and that it was made for exactly this runtime.
    static func open(runtimeID: String, home: URL = URL(fileURLWithPath: NSHomeDirectory())) throws -> SessionNamespace {
        let base = home.appendingPathComponent(".tako-sessions", isDirectory: true)
        let dir = base.appendingPathComponent(try token(for: runtimeID), isDirectory: true)
        for path in [base, dir] {
            try makePrivateDirectory(path)
        }
        let record = dir.appendingPathComponent("runtime-id")
        if let existing = try? String(contentsOf: record, encoding: .utf8) {
            guard existing.trimmingCharacters(in: .whitespacesAndNewlines) == runtimeID else {
                throw Failure.belongsToAnotherRuntime(existing)
            }
        } else {
            try Data((runtimeID + "\n").utf8).write(to: record, options: [.atomic])
        }
        let ns = SessionNamespace(directory: dir, runtimeID: runtimeID)
        let longest = ns.socketPath(for: String(repeating: "f", count: 32))
        guard longest.utf8.count <= socketPathLimit else { throw Failure.pathTooLong(longest.utf8.count) }
        return ns
    }

    private static func makePrivateDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard mkdir(url.path, 0o700) == 0 || errno == EEXIST else { throw Failure.notPrivate(url.path) }
            guard lstat(url.path, &info) == 0 else { throw Failure.notPrivate(url.path) }
        }
        // A real directory (not a link to one), ours, and closed to others.
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw Failure.notPrivate(url.path)
        }
    }

    func socketPath(for name: String) -> String {
        directory.appendingPathComponent(name).path
    }

    /// Environment for every runtime process Tako starts: this namespace,
    /// no detach key, no environment tracking (so nothing of the user's
    /// environment lands in the runtime's logs), private files.
    var environment: [String: String] {
        ["ZMX_DIR": directory.path, "ZMX_NO_DETACH_KEY": "1", "ZMX_TRACK_ENV": "",
         "ZMX_DIR_MODE": "0700", "ZMX_LOG_MODE": "0600"]
    }

    /// Inherited variables that would point a runtime at someone else's
    /// session.
    static let inheritedVariablesToDrop = ["ZMX_SESSION", "ZMX_SESSION_PREFIX", "ZMX_DIR"]
}

/// The one copy of Tako allowed to drive a session: an flock on
/// `<namespace>/<name>.owner`, held while this object lives. The kernel drops
/// it when the process ends, however it ends.
final class SessionOwnerLock {
    enum Failure: Error, Equatable {
        case heldElsewhere
        case unavailable(Int32)
    }

    private let fd: Int32

    init(namespace: SessionNamespace, name: String) throws {
        let path = namespace.directory.appendingPathComponent("\(name).owner").path
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.unavailable(errno) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let reason = errno
            close(fd)
            throw reason == EWOULDBLOCK ? Failure.heldElsewhere : Failure.unavailable(reason)
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

/// What Tako records about a terminal's session, beside its saved screen.
struct SessionRecord: Codable, Equatable {
    enum State: Codable, Equatable {
        /// Written before the session is created; a crash right after it
        /// leaves this, and the next launch checks rather than assumes.
        case creating
        case attached
        case detached
        case error(String)
    }

    var id: UUID
    var runtimeID: String
    /// Set as the session's `tako-gen` label when it is created: the proof,
    /// on reattach, that the session found is the one Tako made.
    var generation: String
    var state: State
    var createdAt: Date

    static func newGeneration() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// Session records on disk, one per terminal, written atomically.
struct SessionRecordStore {
    let directory: URL

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("session")
    }

    func write(_ record: SessionRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(record).write(to: url(for: record.id), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(for: record.id).path)
    }

    enum Read: Equatable {
        case none
        case record(SessionRecord)
        /// A file is there but cannot be read: not "no session".
        case unreadable
    }

    func read(_ id: UUID) -> Read {
        guard FileManager.default.fileExists(atPath: url(for: id).path) else { return .none }
        guard let data = try? Data(contentsOf: url(for: id)),
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data),
              record.id == id
        else { return .unreadable }
        return .record(record)
    }

    func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}

/// How a reattach attempt turned out. The attempt runs the runtime's attach
/// with a sentinel instead of a shell: an existing session ignores it and
/// connects; a missing one is created with only the sentinel, which leaves a
/// marker named for this attempt and exits -- so no user shell ever starts
/// by accident.
enum ReattachOutcome: Equatable {
    /// The session Tako made, with this attempt's client connected to it.
    case live
    /// Settled: there is no such session (the marker of this attempt).
    case absent
    /// Not settled yet.
    case pending
    /// Not settled and no longer waiting: neither live nor absent is known.
    case error(String)
}

enum Reattach {
    /// `zmx get` prints labels as space-separated `key=value`. Exact keys,
    /// exact values; anything malformed means no labels.
    static func labels(from output: String) -> [String: String]? {
        var result: [String: String] = [:]
        for pair in output.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
            guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else { return nil }
            let key = String(pair[..<eq])
            guard result[key] == nil else { return nil }
            result[key] = String(pair[pair.index(after: eq)...])
        }
        return result
    }

    /// Decides from what has been observed so far. `labels` is the parsed
    /// output of a `get` that exited 0, or nil when there is none or it
    /// failed; `marker` is whether this attempt's absent-marker exists;
    /// `clientRunning` whether this attempt's own client is still running.
    static func classify(
        generation: String,
        attempt: String,
        labels: [String: String]?,
        marker: Bool,
        clientRunning: Bool,
        timedOut: Bool
    ) -> ReattachOutcome {
        if marker {
            return .absent
        }
        if let labels, clientRunning,
           labels["tako-gen"] == generation, labels["tako-attempt"] == attempt {
            return .live
        }
        if timedOut {
            if !clientRunning { return .error("the attach client exited without an answer") }
            if let labels, labels["tako-gen"] != generation {
                return .error("the session found is not the one Tako made")
            }
            return .error("the session did not answer in time")
        }
        return .pending
    }

    /// The sentinel script: writes `absent-<attempt>` in the namespace and
    /// exits. Run only by a session the runtime had to create.
    /// It records its parent -- the daemon of the session the runtime
    /// made for it -- so the check can wait for exactly that process to end.
    static func sentinelScript(namespace: SessionNamespace) -> String {
        "#!/bin/sh\nprintf '%s\\n' \"$PPID\" > \"$ZMX_DIR/absent-$1.tmp\" && mv \"$ZMX_DIR/absent-$1.tmp\" \"$ZMX_DIR/absent-$1\"\n"
    }

    static func markerPath(namespace: SessionNamespace, attempt: String) -> String {
        namespace.directory.appendingPathComponent("absent-\(attempt)").path
    }
}

/// What the session runtime's client writes before the session's own
/// output: `session "<name>" created` on a line (LF or CR LF) when the attach made the
/// session, then ESC [2J ESC [H to clear the screen. Passed to the terminal
/// it would wipe the saved screen Tako paints for a session that starts
/// anew, so exactly that opening is removed -- and only it: bytes that do
/// not match are passed on unchanged.
struct SessionClientPreamble {
    private let created: Data
    private static let clear = Data("\u{1b}[2J\u{1b}[H".utf8)
    private var held = Data()
    private var stage = 0
    /// True once the preamble is behind; everything after passes as is.
    private(set) var done = false

    init(sessionName: String) {
        created = Data("session \"\(sessionName)\" created\n".utf8)
    }

    /// Feeds output; returns what belongs to the terminal.
    mutating func consume(_ data: Data) -> Data {
        guard !done else { return data }
        held.append(data)
        while !done {
            // Written before the client puts its terminal in raw mode, the
            // line ending usually arrives as CR LF.
            let expected: Data
            if stage == 0 {
                let crlf = created.dropLast() + Data("\r\n".utf8)
                expected = held.count > created.count - 1 && held[held.startIndex + created.count - 1] == 0x0d
                    ? Data(crlf) : created
            } else {
                expected = Self.clear
            }
            if held.count < expected.count {
                // Still possibly the preamble: wait for more, unless it
                // already differs.
                if expected.starts(with: held) { return Data() }
                if stage == 0 { stage = 1; continue }
                return finish()
            }
            if held.starts(with: expected) {
                held.removeFirst(expected.count)
                if stage == 0 { stage = 1 } else { return finish() }
            } else if stage == 0 {
                // No "created" line: an existing session. Look for the clear.
                stage = 1
            } else {
                return finish()
            }
        }
        return Data()
    }

    private mutating func finish() -> Data {
        done = true
        defer { held = Data() }
        return held
    }
}
