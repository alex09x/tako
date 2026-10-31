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
    var persistenceEnabled: Bool { !SessionPlaces.isSelfTest && (app?.config.sessionPersistence ?? false) }

    /// Says what happened and waits for Return, which tries the session again.
    func awaitReconnect(_ message: String) {
        persistence?.confirmedLive = false
        (NSApp?.delegate as? AppDelegate)?.sessionSaver.protect(id: id)
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

    /// The process in front on the terminal the shell runs on -- the
    /// running command, or the shell itself -- and that terminal. For a
    /// persistent session that is the runtime's terminal, not the client's
    /// pty Tako holds.
    var foregroundProcess: (pid: Int, tty: String?)? {
        if let session = persistence {
            guard let shell = session.shellPID else { return nil }
            return SessionShell.terminal(ofShell: shell).map { ($0.foregroundPID, $0.ttyName) }
        }
        guard let pty, let pid = pty.foregroundPID else { return nil }
        return (pid, pty.ttyName)
    }

    /// The shell's own process.
    var shellProcessID: Int? {
        if let session = persistence { return session.shellPID.map(Int.init) }
        return pty.map { Int($0.child) }
    }

    /// Asks the runtime which process the session's shell is, once it is
    /// attached. A session reattached may have a command running that
    /// another Tako saw start: `adoptingItsCommand` takes it on.
    func learnShellPID(_ session: SurfaceSession, adoptingItsCommand: Bool = false) {
        guard let runtime = session.guardedRuntime else { return }
        let name = session.name, env = session.environment
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let pid = RuntimeCommand.sessionPID(runtime, name: name, environment: env)
            let running = adoptingItsCommand ? pid.flatMap(SessionShell.runningCommand(ofShell:)) : nil
            DispatchQueue.main.async {
                guard let self, self.persistence === session else { return }
                session.shellPID = pid
                if let running { self.adoptRunningCommand(running, quietSince: session.record.quietSince) }
            }
        }
    }

    /// A quiet program -- ssh, `tail -f`, an agent -- runs on as it did
    /// before Tako restarted, and its tab shows it live again, quiet since
    /// `quietSince` -- when the last Tako saw it print -- not since now. A
    /// job is left alone: its clock would start now, not when it did.
    func adoptRunningCommand(_ line: String, quietSince: Date? = nil) {
        guard !isCommandRunning else { return }
        let kind = commandKind(of: line)
        guard kind != .batch else { return }
        crab.isFocused = isBeingLookedAt
        crab.commandStarted(kind: kind, probe: liveProbe(for: line), quietSince: quietSince)
        commandStarted()
        Tako.TabBarController.refreshAll()
    }

    /// A line from Tako, not from the shell, in the terminal itself.
    func sessionNotice(_ text: String) {
        core.feed(bytes: Data("\r\n\u{1b}[33m[Tako] \(text)\u{1b}[0m\r\n".utf8))
        scheduleRedraw()
    }

    /// With session-persistence: a new terminal creates its session; a
    /// restored one that had a session checks it before anything of the
    /// user's runs. Whatever cannot be established is said in the terminal
    /// and nothing starts in its place when the runtime is unavailable.
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
                if let snapshot { showSnapshot(snapshot) }
                sessionNotice("This terminal had a session, but its record is gone. Nothing was started; the session, if it still runs, is left alone. Press Return to try again.")
                return
            case .unreadable:
                if let snapshot { showSnapshot(snapshot) }
                sessionNotice("This terminal's session record cannot be read. Nothing was started; the session, if it still runs, is left alone. Press Return to try again.")
                return
            }
            guard let opened = openSession(registry: registry, runtimeID: record.runtimeID, name: name, snapshot: snapshot) else {
                return
            }
            let session = SurfaceSession(runtime: opened.runtime, guardedRuntime: opened.guardedRuntime, namespace: opened.namespace, name: name,
                                         owner: opened.owner, records: records, record: record)
            sessionRetry = nil
            persistence = session
            session.register()
            reattach(session, workingDir: workingDir, snapshot: snapshot)
            return
        }

        // An older layout may omit the persistent flag even though this pane
        // already has a session record. Never overwrite that identity.
        switch records.read(id) {
        case .record:
            launchPersistentSession(workingDir: workingDir, snapshot: snapshot, restored: true,
                                    hadPersistentSession: true)
            return
        case .unreadable:
            self.hadPersistentSession = true
            sessionRetry = { [weak self] in
                guard let self else { return }
                self.sessionRetry = nil
                self.launchPersistentSession(workingDir: workingDir, snapshot: snapshot, restored: true,
                                             hadPersistentSession: true)
            }
            if let snapshot { showSnapshot(snapshot) }
            sessionNotice("This terminal has an unreadable session record. Nothing was started. Press Return to try again.")
            return
        case .none:
            break
        }

        if SessionCollisionGuard.mayContainSession(id: id, home: SessionPlaces.home) {
            self.hadPersistentSession = true
            if let snapshot { showSnapshot(snapshot) }
            sessionRetry = { [weak self] in
                self?.launchPersistentSession(workingDir: workingDir, snapshot: snapshot,
                                              restored: restored, hadPersistentSession: false)
            }
            sessionNotice("A session with this pane ID may still exist. Nothing was started. Use File → Recover Sessions to review it, or press Return to retry.")
            return
        }

        // A new terminal, or one saved before persistence was on: a new
        // session on the runtime this Tako carries.
        let runtimeID: String
        do {
            let bundled = try SessionRuntimeRegistry.bundled(in: Bundle.main.bundleURL)
            runtimeID = try registry.install(manifest: bundled.manifest, from: bundled.executable)
        } catch {
            self.hadPersistentSession = true
            if let snapshot { showSnapshot(snapshot) }
            sessionRetry = { [weak self] in
                guard let self else { return }
                self.sessionRetry = nil
                self.launchPersistentSession(workingDir: workingDir, snapshot: snapshot, restored: restored,
                                             hadPersistentSession: false)
            }
            sessionNotice("Session persistence is on, but its runtime is unavailable (\(error)). Nothing was started. Press Return to try again.")
            return
        }
        self.hadPersistentSession = true
        sessionRetry = { [weak self] in
            guard let self else { return }
            self.sessionRetry = nil
            self.launchPersistentSession(workingDir: workingDir, snapshot: snapshot, restored: restored,
                                         hadPersistentSession: false)
        }
        guard let opened = openSession(registry: registry, runtimeID: runtimeID, name: name, snapshot: snapshot) else {
            return
        }
        let record = SessionRecord(id: id, runtimeID: runtimeID, generation: SessionRecord.newGeneration(),
                                   state: .creating, createdAt: Date())
        let session = SurfaceSession(runtime: opened.runtime, guardedRuntime: opened.guardedRuntime, namespace: opened.namespace, name: name,
                                     owner: opened.owner, records: records, record: record)
        persistence = session
        session.register()
        sessionRetry = nil
        if let snapshot { showSnapshot(snapshot) }
        createSession(session, workingDir: workingDir)
    }

    /// Resolves the runtime by id, opens its namespace and takes the owner
    /// lock -- in that order, before anything touches the session. Nil
    /// (after saying why) when any of it fails.
    private func openSession(registry: SessionRuntimeRegistry, runtimeID: String, name: String, snapshot: SessionSnapshot?)
        -> (runtime: URL, guardedRuntime: URL, namespace: SessionNamespace, owner: SessionOwnerLock)? {
        do {
            let guardedRuntime = try registry.guardedClient(in: Bundle.main.bundleURL)
            let runtime = (try? registry.executable(for: runtimeID)) ?? guardedRuntime
            let namespace = try SessionNamespace.open(runtimeID: runtimeID, home: SessionPlaces.home)
            let owner = try SessionOwnerLock(namespace: namespace, name: name)
            return (runtime, guardedRuntime, namespace, owner)
        } catch SessionOwnerLock.Failure.heldElsewhere {
            if let snapshot { showSnapshot(snapshot) }
            sessionNotice("This session is open in another copy of Tako. Close it there, then press Return here.")
        } catch {
            if let snapshot { showSnapshot(snapshot) }
            sessionNotice("This terminal's session cannot be reached (\(error)). Nothing was started.")
        }
        return nil
    }

    /// Starts a new session. Its record is written first (`creating`) and
    /// nothing runs if that fails; `attached` follows only once the session
    /// answers with its generation.
    private func createSession(_ session: SurfaceSession, workingDir: String?) {
        session.confirmedLive = false
        if SessionCollisionGuard.mayContainSession(id: id, home: SessionPlaces.home) {
            session.ended = true
            persistence = nil
            sessionRetry = { [weak self] in
                self?.launchPersistentSession(workingDir: workingDir, snapshot: nil,
                                              restored: true, hadPersistentSession: false)
            }
            sessionNotice("A session with this pane ID may still exist. Nothing was started. Use File → Recover Sessions to review it, or press Return to retry.")
            return
        }
        guard let guardedRuntime = session.guardedRuntime else {
            sessionNotice("The guarded session client is unavailable. Nothing was started.")
            return
        }
        do {
            try session.save(.creating)
        } catch {
            sessionRetry = { [weak self, weak session] in
                guard let self, let session, self.persistence === session else { return }
                self.sessionRetry = nil
                self.createSession(session, workingDir: workingDir)
            }
            sessionNotice("This terminal's session record cannot be written (\(error)). Nothing was started. Press Return to try again.")
            return
        }
        startProcess(
            workingDir: workingDir,
            program: [guardedRuntime.path] + RuntimeCommand.createOnlyWithGenerationArguments(
                name: session.name, generation: session.record.generation, command: [PTY.loginShell, "-l"]),
            environment: session.environment,
            removing: SessionNamespace.inheritedVariablesToDrop,
            sessionPreamble: session.name)
        reflowToCurrentBounds(forcePtyResize: true)
        guard let client = pty else {
            awaitReconnect("The session client could not be started. Press Return to check whether the session exists.")
            return
        }
        let runtime = guardedRuntime, name = session.name, env = session.environment
        let generation = session.record.generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let deadline = DispatchTime.now() + SurfaceSession.reattachTimeout
            var confirmed = false
            while !confirmed && DispatchTime.now() < deadline && client.alive {
                let get = RuntimeCommand.run(runtime, ["get", name], environment: env)
                let labels = get.flatMap { $0.status == 0 ? Reattach.labels(from: $0.output) : nil }
                confirmed = labels?["tako-gen"] == generation
                if !confirmed { usleep(150_000) }
            }
            DispatchQueue.main.async {
                guard let self, self.persistence === session, self.pty === client else { return }
                guard confirmed else {
                    self.awaitReconnect("The new session could not be verified. Press Return to check it again.")
                    return
                }
                session.confirmedLive = true
                self.learnShellPID(session)
                do {
                    try session.save(.attached)
                } catch {
                    // `creating` keeps the generation: the next launch checks it.
                    self.sessionNotice("The session is running, but its record could not be updated (\(error)).")
                }
            }
        }
    }

    /// Reattach with a verified client. This never creates a replacement
    /// daemon when an existing session is absent or cannot be verified.
    fileprivate func reattach(_ session: SurfaceSession, workingDir: String?, snapshot: SessionSnapshot?) {
        session.confirmedLive = false
        guard let guardedRuntime = session.guardedRuntime else {
            sessionNotice("The guarded session client is unavailable. Nothing was started.")
            return
        }
        let attempt = SessionRecord.newGeneration()
        session.attempt = attempt
        startProcess(
            workingDir: workingDir,
            program: [guardedRuntime.path] + RuntimeCommand.attachOnlyIfGenerationArguments(
                name: session.name, generation: session.record.generation, attempt: attempt),
            environment: session.environment,
            removing: SessionNamespace.inheritedVariablesToDrop,
            sessionPreamble: session.name)
        guard let client = pty else {
            session.attempt = nil
            sessionNotice("The session client could not be started. Nothing is running.")
            return
        }

        let runtime = guardedRuntime, name = session.name, env = session.environment
        let generation = session.record.generation
        let deadline = DispatchTime.now() + SurfaceSession.reattachTimeout
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var outcome = ReattachOutcome.pending
            while case .pending = outcome {
                let get = RuntimeCommand.run(runtime, ["get", name], environment: env)
                let labels = get.flatMap { $0.status == 0 ? Reattach.labels(from: $0.output) : nil }
                let clientRunning = client.alive
                outcome = Reattach.classify(
                    generation: generation, attempt: attempt, labels: labels,
                    marker: false,
                    // This attempt's own client, by its own record of ending.
                    clientRunning: clientRunning, timedOut: !clientRunning || DispatchTime.now() > deadline)
                if case .pending = outcome { usleep(150_000) }
            }
            let settled = outcome
            DispatchQueue.main.async {
                // Only the attempt that is still current may act on its outcome.
                guard let self, self.persistence === session, session.attempt == attempt, self.pty === client
                else { return }
                self.reattachSettled(session, settled, workingDir: workingDir, snapshot: snapshot)
            }
        }
    }

    private func reattachSettled(_ session: SurfaceSession, _ outcome: ReattachOutcome,
                                 workingDir: String?, snapshot: SessionSnapshot?) {
        session.attempt = nil
        switch outcome {
        case .live:
            session.confirmedLive = true
            learnShellPID(session, adoptingItsCommand: true)
            do {
                try session.save(.attached)
            } catch {
                sessionNotice("Reattached, but the session record could not be updated (\(error)).")
            }
            reflowToCurrentBounds(forcePtyResize: true)
        case .absent:
            // Absence is not proof that replacing this identity is safe.
            reattachSettled(session, .error("session is not available"), workingDir: workingDir, snapshot: snapshot)
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
                    if let snapshot {
                        self.showSnapshot(snapshot)
                        self.sessionNotice("Saved screen from the previous session.")
                    }
                    self.sessionNotice("This session could not be checked (\(reason)). It may still be running. Press Return to retry, or open a new tab for a new shell.")
                }
            }
        case .pending:
            break
        }
    }
}
