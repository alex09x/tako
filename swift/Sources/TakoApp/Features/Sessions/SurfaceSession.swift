import AppKit
import Foundation

/// A terminal's persistent session: which runtime and namespace it uses,
/// the owner lock that keeps every other copy of Tako away from it while
/// this one drives it, and -- while a relaunched terminal is checking
/// whether its session survived -- that check.
@MainActor
final class SurfaceSession {
    let runtime: URL
    let namespace: SessionNamespace
    let name: String
    let owner: SessionOwnerLock
    let records: SessionRecordStore
    var record: SessionRecord

    /// This attempt's nonce while a reattach check has not been decided.
    fileprivate var attempt: String?

    init(runtime: URL, namespace: SessionNamespace, name: String, owner: SessionOwnerLock,
         records: SessionRecordStore, record: SessionRecord) {
        self.runtime = runtime
        self.namespace = namespace
        self.name = name
        self.owner = owner
        self.records = records
        self.record = record
    }

    /// The client of a reattach check ends on its own when the session was
    /// gone; that is part of the check, not the terminal closing.
    func clientExited(_ surface: Tako.SurfaceView) -> Bool {
        attempt != nil
    }

    var environment: [String: String] { namespace.environment }

    func save(_ state: SessionRecord.State) throws {
        var next = record
        next.state = state
        try records.write(next)
        record = next
    }
}

/// Where session state lives. TAKO_SESSIONS_HOME moves the namespace for the
/// isolated e2e profile; records and runtimes follow the app's own
/// Application Support, which a separate bundle id keeps apart.
enum SessionPlaces {
    static var support: URL { SessionSnapshotStore.shared.directory.deletingLastPathComponent() }
    static var records: SessionRecordStore {
        SessionRecordStore(directory: support.appendingPathComponent("SessionRecords", isDirectory: true))
    }
    static var registry: SessionRuntimeRegistry { SessionRuntimeRegistry(root: support) }
    static var home: URL {
        ProcessInfo.processInfo.environment["TAKO_SESSIONS_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }
}

/// Set from the reader thread, read after it finished.
private final class OverflowFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// Runs a runtime command with the namespace's environment, bounded in time
/// and in what it keeps of the output. Nil when it could not run or finish.
enum RuntimeCommand {
    static let outputLimit = 1 << 20

    static func run(_ runtime: URL, _ args: [String], environment: [String: String],
                    timeout: TimeInterval = 2) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = runtime
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        for key in SessionNamespace.inheritedVariablesToDrop { env.removeValue(forKey: key) }
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        // Read while it runs, so a long answer cannot fill the pipe and stall
        // it. Past the cap the rest is still drained, but the answer is
        // incomplete and so no answer at all.
        let reader = out.fileHandleForReading
        let collected = NSMutableData()
        let overflow = OverflowFlag()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                let room = outputLimit - collected.length
                if chunk.count <= room {
                    collected.append(chunk)
                } else {
                    overflow.set()
                }
            }
            done.signal()
        }
        // Monotonic, and every wait bounded: a helper that ignores SIGTERM
        // gets SIGKILL -- this helper process only, never a session daemon.
        let deadline = DispatchTime.now() + timeout
        while process.isRunning && DispatchTime.now() < deadline { usleep(20_000) }
        if process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            let grace = DispatchTime.now() + 1
            while process.isRunning && DispatchTime.now() < grace { usleep(20_000) }
            if process.isRunning { kill(pid, SIGKILL) }
            let reap = DispatchTime.now() + 1
            while process.isRunning && DispatchTime.now() < reap { usleep(20_000) }
            _ = done.wait(timeout: .now() + 1)
            return nil
        }
        guard done.wait(timeout: .now() + 1) == .success, !overflow.isSet else { return nil }
        return (process.terminationStatus, String(decoding: collected as Data, as: UTF8.self))
    }

    /// Whether `zmx list` shows exactly this name. Nil when it cannot tell.
    static func isListed(_ runtime: URL, name: String, environment: [String: String]) -> Bool? {
        guard let result = run(runtime, ["list"], environment: environment), result.status == 0 else { return nil }
        return result.output.split(separator: "\n").contains { $0.split(separator: "\t").first == "name=\(name)" }
    }
}

extension Tako.SurfaceView {
    var persistenceEnabled: Bool { app?.config.sessionPersistence ?? false }

    /// A line from Tako, not from the shell, in the terminal itself.
    func sessionNotice(_ text: String) {
        core.feed(bytes: Data("\r\n\u{1b}[33m[Tako] \(text)\u{1b}[0m\r\n".utf8))
        scheduleRedraw()
    }

    /// With session-persistence: a new terminal creates its session; a
    /// restored one that had a session checks it before anything of the
    /// user's runs. Whatever cannot be established is said in the terminal
    /// and nothing starts in its place -- except for a terminal that never
    /// had a session, which falls back to a plain shell when this Tako has
    /// no runtime.
    func launchPersistentSession(workingDir: String?, snapshot: SessionSnapshot?, restored: Bool,
                                 hadPersistentSession: Bool) {
        let records = SessionPlaces.records
        let registry = SessionPlaces.registry
        let name = SessionNamespace.sessionName(for: id)

        if restored && hadPersistentSession {
            self.hadPersistentSession = true
            // Its own record first, and the runtime it pins -- the runtime
            // this Tako carries has no say over a session another one made.
            let record: SessionRecord
            switch records.read(id) {
            case .record(let r):
                record = r
            case .none:
                sessionNotice("This terminal had a session, but its record is gone. Nothing was started; the session, if it still runs, is left alone.")
                return
            case .unreadable:
                sessionNotice("This terminal's session record cannot be read. Nothing was started; the session, if it still runs, is left alone.")
                return
            }
            guard let opened = openSession(registry: registry, runtimeID: record.runtimeID, name: name) else { return }
            let session = SurfaceSession(runtime: opened.runtime, namespace: opened.namespace, name: name,
                                         owner: opened.owner, records: records, record: record)
            persistence = session
            reattach(session, workingDir: workingDir, snapshot: snapshot)
            return
        }

        // A new terminal, or one saved before persistence was on: a new
        // session on the runtime this Tako carries.
        let runtimeID: String
        do {
            let bundled = try SessionRuntimeRegistry.bundled(in: Bundle.main.bundleURL)
            runtimeID = try registry.install(manifest: bundled.manifest, from: bundled.executable)
        } catch {
            sessionNotice("session-persistence is on, but this Tako has no usable session runtime (\(error)). This terminal's shell will not outlive Tako.")
            if let snapshot { showSnapshot(snapshot) }
            startProcess(workingDir: workingDir)
            return
        }
        self.hadPersistentSession = true
        guard let opened = openSession(registry: registry, runtimeID: runtimeID, name: name) else { return }
        let record = SessionRecord(id: id, runtimeID: runtimeID, generation: SessionRecord.newGeneration(),
                                   state: .creating, createdAt: Date())
        let session = SurfaceSession(runtime: opened.runtime, namespace: opened.namespace, name: name,
                                     owner: opened.owner, records: records, record: record)
        persistence = session
        if let snapshot { showSnapshot(snapshot) }
        createSession(session, workingDir: workingDir)
    }

    /// Resolves the runtime by id, opens its namespace and takes the owner
    /// lock -- in that order, before anything touches the session. Nil
    /// (after saying why) when any of it fails.
    private func openSession(registry: SessionRuntimeRegistry, runtimeID: String, name: String)
        -> (runtime: URL, namespace: SessionNamespace, owner: SessionOwnerLock)? {
        do {
            let runtime = try registry.executable(for: runtimeID)
            let namespace = try SessionNamespace.open(runtimeID: runtimeID, home: SessionPlaces.home)
            let owner = try SessionOwnerLock(namespace: namespace, name: name)
            return (runtime, namespace, owner)
        } catch SessionOwnerLock.Failure.heldElsewhere {
            sessionNotice("This session is open in another copy of Tako. Close it there to use it here.")
        } catch {
            sessionNotice("This terminal's session cannot be reached (\(error)). Nothing was started.")
        }
        return nil
    }

    /// Starts a new session. Its record is written first (`creating`) and
    /// nothing runs if that fails; `attached` follows only once the session
    /// answers with its generation.
    private func createSession(_ session: SurfaceSession, workingDir: String?) {
        do {
            try session.save(.creating)
        } catch {
            sessionNotice("This terminal's session record cannot be written (\(error)). Nothing was started.")
            return
        }
        startProcess(
            workingDir: workingDir,
            program: [session.runtime.path, "attach", "--labels", "tako-gen=\(session.record.generation)",
                      session.name, PTY.loginShell, "-l"],
            environment: session.environment,
            removing: SessionNamespace.inheritedVariablesToDrop,
            sessionPreamble: session.name)
        guard let client = pty else {
            sessionNotice("The session client could not be started. Nothing is running.")
            return
        }
        let runtime = session.runtime, name = session.name, env = session.environment
        let generation = session.record.generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let deadline = Date().addingTimeInterval(SurfaceSession.reattachTimeout)
            var confirmed = false
            while !confirmed && Date() < deadline && client.alive {
                let get = RuntimeCommand.run(runtime, ["get", name], environment: env)
                let labels = get.flatMap { $0.status == 0 ? Reattach.labels(from: $0.output) : nil }
                confirmed = labels?["tako-gen"] == generation
                if !confirmed { usleep(150_000) }
            }
            DispatchQueue.main.async {
                guard let self, self.persistence === session, self.pty === client, confirmed else { return }
                do {
                    try session.save(.attached)
                } catch {
                    // `creating` keeps the generation: the next launch checks it.
                    self.sessionNotice("The session is running, but its record could not be updated (\(error)).")
                }
            }
        }
    }

    /// Reattach check: the client runs the runtime's attach with a sentinel
    /// in place of a shell, and the outcome is decided from labels, this
    /// attempt's marker and whether this attempt's own client still runs.
    private func reattach(_ session: SurfaceSession, workingDir: String?, snapshot: SessionSnapshot?) {
        let attempt = SessionRecord.newGeneration()
        session.attempt = attempt
        let sentinel = session.namespace.directory.appendingPathComponent("tako-sentinel.sh")
        do {
            try Data(Reattach.sentinelScript(namespace: session.namespace).utf8).write(to: sentinel, options: .atomic)
            chmod(sentinel.path, 0o700)
        } catch {
            session.attempt = nil
            sessionNotice("Could not prepare the session check (\(error)). Nothing was started.")
            return
        }
        startProcess(
            workingDir: workingDir,
            program: [session.runtime.path, "attach", "--labels", "tako-attempt=\(attempt)",
                      session.name, sentinel.path, attempt],
            environment: session.environment,
            removing: SessionNamespace.inheritedVariablesToDrop,
            sessionPreamble: session.name)
        guard let client = pty else {
            session.attempt = nil
            sessionNotice("The session client could not be started. Nothing is running.")
            return
        }

        let runtime = session.runtime, name = session.name, env = session.environment
        let generation = session.record.generation
        let marker = Reattach.markerPath(namespace: session.namespace, attempt: attempt)
        let deadline = Date().addingTimeInterval(SurfaceSession.reattachTimeout)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var outcome = ReattachOutcome.pending
            while case .pending = outcome {
                let get = RuntimeCommand.run(runtime, ["get", name], environment: env)
                let labels = get.flatMap { $0.status == 0 ? Reattach.labels(from: $0.output) : nil }
                outcome = Reattach.classify(
                    generation: generation, attempt: attempt, labels: labels,
                    marker: FileManager.default.fileExists(atPath: marker),
                    // This attempt's own client, by its own record of ending.
                    clientRunning: client.alive, timedOut: Date() > deadline)
                if case .pending = outcome { usleep(150_000) }
            }
            if case .absent = outcome {
                outcome = Self.waitForTemporarySession(runtime: runtime, name: name, environment: env,
                                                       marker: marker, client: client)
            }
            try? FileManager.default.removeItem(atPath: marker)
            let settled = outcome
            DispatchQueue.main.async {
                // Only the attempt that is still current may act on its outcome.
                guard let self, self.persistence === session, session.attempt == attempt, self.pty === client
                else { return }
                self.reattachSettled(session, settled, workingDir: workingDir, snapshot: snapshot)
            }
        }
    }

    /// The session the runtime made for the sentinel must be gone before a
    /// new session takes the name: its daemon (the sentinel's parent, which
    /// the sentinel wrote into the marker) ended, this attempt's client
    /// ended, and the name no longer listed. Not knowing is an error, never
    /// "gone".
    nonisolated private static func waitForTemporarySession(runtime: URL, name: String, environment: [String: String],
                                                            marker: String, client: PTY) -> ReattachOutcome {
        guard let text = try? String(contentsOfFile: marker, encoding: .utf8),
              let daemon = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), daemon > 1
        else { return .error("the check could not tell which process held the temporary session") }
        let deadline = Date().addingTimeInterval(SurfaceSession.reattachTimeout)
        while Date() < deadline {
            let daemonGone = kill(daemon, 0) != 0 && errno == ESRCH
            if daemonGone, !client.alive,
               RuntimeCommand.isListed(runtime, name: name, environment: environment) == false {
                return .absent
            }
            usleep(100_000)
        }
        return .error("the temporary session did not end")
    }

    private func reattachSettled(_ session: SurfaceSession, _ outcome: ReattachOutcome,
                                 workingDir: String?, snapshot: SessionSnapshot?) {
        session.attempt = nil
        switch outcome {
        case .live:
            do {
                try session.save(.attached)
            } catch {
                sessionNotice("Reattached, but the session record could not be updated (\(error)).")
            }
        case .absent:
            // The shell did not survive (the Mac restarted, it exited): the
            // saved screen, then a new session in its place. The old client's
            // last output is parsed (and dropped) first, so the saved screen
            // is painted after it, never under it.
            let old = pty
            currentProcess = nil
            pty = nil
            old?.terminate()
            afterPendingOutput { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.persistence === session, self.pty == nil else { return }
                    if let snapshot { self.showSnapshot(snapshot) }
                    session.record.generation = SessionRecord.newGeneration()
                    self.createSession(session, workingDir: workingDir)
                }
            }
        case .error(let reason):
            let old = pty
            currentProcess = nil
            pty = nil
            old?.terminate()
            try? session.save(.error(reason))
            // After the old client's last bytes, so its closing reset cannot
            // wipe the only message the user gets.
            afterPendingOutput { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.persistence === session, self.pty == nil else { return }
                    self.sessionNotice("This terminal's session could not be checked (\(reason)). Nothing was started; the session, if it exists, is left running.")
                }
            }
        case .pending:
            break
        }
    }
}

extension SurfaceSession {
    nonisolated static let reattachTimeout: TimeInterval = 5
}
