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

    /// Set once quitting is confirmed: from then on clients are detached,
    /// never their sessions ended. Read from any thread (a deinit).
    nonisolated(unsafe) private static var detachingFlag = false
    private static let detachingLock = NSLock()
    nonisolated static var appIsDetaching: Bool {
        get { detachingLock.withLock { detachingFlag } }
        set { detachingLock.withLock { detachingFlag = newValue } }
    }

    init(runtime: URL, namespace: SessionNamespace, name: String, owner: SessionOwnerLock,
         records: SessionRecordStore, record: SessionRecord) {
        self.runtime = runtime
        self.namespace = namespace
        self.name = name
        self.owner = owner
        self.records = records
        self.record = record
    }

    /// The terminal's process ended. Handled here (true) when that is not
    /// the terminal closing: a reattach check's client ends on its own,
    /// clients end on purpose while Tako quits, and a client that ends on
    /// its own may have left its session running -- that is found out first.
    func clientExited(_ surface: Tako.SurfaceView) -> Bool {
        if attempt != nil || Self.appIsDetaching { return true }
        let runtime = self.runtime, name = self.name, env = environment
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak surface] in
            let listed = RuntimeCommand.isListed(runtime, name: name, environment: env)
            DispatchQueue.main.async {
                guard let self, let surface, surface.persistence === self, surface.pty == nil || !(surface.pty?.alive ?? false)
                else { return }
                switch listed {
                case false:
                    // The shell ended (exit, Ctrl-D): so did the session.
                    self.records.remove(self.record.id)
                    self.ended = true
                    surface.onExit?(surface)
                case true:
                    try? self.save(.detached)
                    surface.awaitReconnect("Disconnected from this terminal's session; it is still running. Press Return to reconnect.")
                case nil:
                    surface.awaitReconnect("Could not tell whether this terminal's session is still running. Press Return to check again.")
                }
            }
        }
        return true
    }

    /// Set once ending the session is taken care of -- it is over, or an
    /// Ending owns it -- so nothing starts a second one.
    var ended = false

    /// Every session object alive in this process, including those of
    /// closed terminals still held for undo. Weak: it keeps nothing alive.
    private static let live = NSHashTable<SurfaceSession>.weakObjects()

    func register() { Self.live.add(self) }

    /// The surface is gone for good -- closed, and past any undo that could
    /// bring it back -- and Tako is not quitting: its session ends with it.
    deinit {
        guard !Self.appIsDetaching, !ended else { return }
        Ending(runtime: runtime, name: name, environment: namespace.environment, records: records,
               id: record.id, generation: record.generation, owner: owner).start()
    }

    /// Quitting is confirmed: open terminals let go of their sessions --
    /// recorded as detached, clients ended -- while terminals already closed
    /// (held only for undo, never coming back) have theirs ended first,
    /// within a bound. After this no client exit closes a tab and no
    /// session is ended.
    static func detachAll(_ surfaces: [Tako.SurfaceView]) {
        let open = Set(surfaces.compactMap { $0.persistence.map(ObjectIdentifier.init) })
        // Terminals closed but still held for undo are not coming back:
        // their sessions end now, like any closed terminal's.
        for session in live.allObjects where !open.contains(ObjectIdentifier(session)) && !session.ended {
            session.ended = true
            Ending(session).start(reportFailure: false)
        }
        // Every ending still under way -- these, and those started earlier
        // when an undo expired -- gets a bounded time to finish. Whatever
        // has not finished is recorded so the next launch asks about it.
        Ending.settleBeforeQuit(within: 4)
        appIsDetaching = true
        for surface in surfaces {
            guard let session = surface.persistence else { continue }
            if !session.ended { try? session.save(.detached) }
            let client = surface.pty
            surface.currentProcess = nil
            client?.terminate()
        }
    }

    var environment: [String: String] { namespace.environment }

    func save(_ state: SessionRecord.State) throws {
        var next = record
        next.state = state
        try records.write(next)
        record = next
    }
}

/// Ending a closed terminal's session. It holds the owner lock until it is
/// settled -- so no other copy of Tako can take the session over in between
/// -- ends only the session it made (the record still names its generation),
/// and removes the record only once the session is confirmed gone. Until
/// then it stays registered: quitting waits for it, a failure is shown with
/// a way to try again, and one left unsettled at quit is asked about on the
/// next launch.
final class Ending: @unchecked Sendable {
    static let closedButRunning = "closed, but its session could not be ended"

    let runtime: URL
    let name: String
    let environment: [String: String]
    let records: SessionRecordStore
    let id: UUID
    let generation: String
    let owner: SessionOwnerLock

    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [ObjectIdentifier: Ending] = [:]
    private let finished = DispatchSemaphore(value: 0)

    init(runtime: URL, name: String, environment: [String: String], records: SessionRecordStore,
         id: UUID, generation: String, owner: SessionOwnerLock) {
        self.runtime = runtime
        self.name = name
        self.environment = environment
        self.records = records
        self.id = id
        self.generation = generation
        self.owner = owner
    }

    @MainActor convenience init(_ session: SurfaceSession) {
        self.init(runtime: session.runtime, name: session.name, environment: session.namespace.environment,
                  records: session.records, id: session.record.id, generation: session.record.generation,
                  owner: session.owner)
    }

    static var pendingCount: Int { lock.withLock { pending.count } }

    /// Registers this ending and runs it in the background.
    func start(reportFailure: Bool = true) {
        Self.lock.withLock { Self.pending[ObjectIdentifier(self)] = self }
        DispatchQueue.global(qos: .utility).async { self.run(reportFailure: reportFailure) }
    }

    private func settle() {
        _ = Self.lock.withLock { Self.pending.removeValue(forKey: ObjectIdentifier(self)) }
        finished.signal()
    }

    /// True when the session is confirmed gone (or was never this ending's).
    @discardableResult
    func run(reportFailure: Bool = true) -> Bool {
        if case .record(let record) = records.read(id), record.generation != generation {
            settle()
            return true
        }
        _ = RuntimeCommand.run(runtime, ["kill", name], environment: environment, timeout: 3)
        if RuntimeCommand.isListed(runtime, name: name, environment: environment) == false {
            records.remove(id)
            settle()
            return true
        }
        markClosedButRunning()
        guard reportFailure else { return false }
        DispatchQueue.main.async {
            if Self.askAgain(self.name) {
                DispatchQueue.global(qos: .utility).async { self.run() }
            } else {
                self.leaveRunning()
            }
        }
        return false
    }

    /// The record says what is pending, so it survives the app ending.
    private func markClosedButRunning() {
        if case .record(var record) = records.read(id), record.generation == generation {
            record.state = .error(Self.closedButRunning)
            try? records.write(record)
        }
    }

    /// The user chose to leave the session running: Tako forgets it.
    func leaveRunning() {
        records.remove(id)
        settle()
    }

    @MainActor static func askAgain(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "A closed terminal is still running"
        alert.informativeText = "Its session could not be ended. Try again, or leave it running -- Tako will then stop tracking it."
        alert.addButton(withTitle: "Try Again")
        alert.addButton(withTitle: "Leave It Running")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Quitting: waits up to `seconds` for every ending under way. Those
    /// still unsettled are marked in their records; the next launch asks.
    static func settleBeforeQuit(within seconds: TimeInterval) {
        let deadline = DispatchTime.now() + seconds
        for ending in lock.withLock({ Array(pending.values) }) {
            if ending.finished.wait(timeout: deadline) == .timedOut {
                ending.markClosedButRunning()
            }
        }
    }

    /// At launch: sessions of terminals closed before Tako last quit that
    /// could not be ended. Each is asked about: end it, or leave it running.
    @MainActor static func askAboutLeftovers(records: SessionRecordStore, registry: SessionRuntimeRegistry,
                                             home: URL, openIDs: Set<UUID>) {
        for record in records.all() where !openIDs.contains(record.id) {
            guard case .error(let reason) = record.state, reason == closedButRunning else { continue }
            let alert = NSAlert()
            alert.messageText = "A terminal closed before Tako last quit is still running"
            alert.informativeText = "Its session could not be ended then. End it now, or leave it running -- Tako will then stop tracking it."
            alert.addButton(withTitle: "End It")
            alert.addButton(withTitle: "Leave It Running")
            guard alert.runModal() == .alertFirstButtonReturn else {
                records.remove(record.id)
                continue
            }
            let name = SessionNamespace.sessionName(for: record.id)
            guard let runtime = try? registry.executable(for: record.runtimeID),
                  let namespace = try? SessionNamespace.open(runtimeID: record.runtimeID, home: home),
                  let owner = try? SessionOwnerLock(namespace: namespace, name: name)
            else { continue }   // Still marked: asked again next launch.
            Ending(runtime: runtime, name: name, environment: namespace.environment, records: records,
                   id: record.id, generation: record.generation, owner: owner).start()
        }
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

    /// Says what happened and waits for Return, which tries the session again.
    func awaitReconnect(_ message: String) {
        let old = pty
        currentProcess = nil
        pty = nil
        old?.terminate()
        sessionNotice(message)
        sessionRetry = { [weak self] in
            guard let self, let session = self.persistence else { return }
            self.sessionRetry = nil
            self.reattach(session, workingDir: nil, snapshot: nil)
        }
    }

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
            // Whatever stops it below can be tried again with Return.
            sessionRetry = { [weak self] in
                guard let self else { return }
                self.sessionRetry = nil
                self.launchPersistentSession(workingDir: workingDir, snapshot: snapshot, restored: true,
                                             hadPersistentSession: true)
            }
            // Its own record first, and the runtime it pins -- the runtime
            // this Tako carries has no say over a session another one made.
            let record: SessionRecord
            switch records.read(id) {
            case .record(let r):
                record = r
            case .none:
                sessionNotice("This terminal had a session, but its record is gone. Nothing was started; the session, if it still runs, is left alone. Press Return to try again.")
                return
            case .unreadable:
                sessionNotice("This terminal's session record cannot be read. Nothing was started; the session, if it still runs, is left alone. Press Return to try again.")
                return
            }
            guard let opened = openSession(registry: registry, runtimeID: record.runtimeID, name: name) else { return }
            let session = SurfaceSession(runtime: opened.runtime, namespace: opened.namespace, name: name,
                                         owner: opened.owner, records: records, record: record)
            sessionRetry = nil
            persistence = session
            session.register()
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
        session.register()
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
            sessionNotice("This session is open in another copy of Tako. Close it there, then press Return here.")
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
    fileprivate func reattach(_ session: SurfaceSession, workingDir: String?, snapshot: SessionSnapshot?) {
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
            sessionRetry = { [weak self] in
                guard let self, self.persistence === session else { return }
                self.sessionRetry = nil
                self.reattach(session, workingDir: workingDir, snapshot: snapshot)
            }
            // After the old client's last bytes, so its closing reset cannot
            // wipe the only message the user gets.
            afterPendingOutput { [weak self] in
                DispatchQueue.main.async {
                    guard let self, self.persistence === session, self.pty == nil else { return }
                    self.sessionNotice("This terminal's session could not be checked (\(reason)). Nothing was started; the session, if it exists, is left running. Press Return to try again.")
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
