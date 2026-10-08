/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation

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
                sessionRetry = { [weak self] in
                    guard let self else { return }
                    self.sessionRetry = nil
                    self.launchPersistentSession(workingDir: workingDir, snapshot: snapshot, restored: false,
                                                 hadPersistentSession: false)
                }
                sessionNotice("This terminal had a session, but its record is gone. Press Return to start a new session.")
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
        reflowToCurrentBounds(forcePtyResize: true)
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
            reflowToCurrentBounds(forcePtyResize: true)
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
