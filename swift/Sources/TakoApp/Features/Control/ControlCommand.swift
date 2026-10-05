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

/// `takoctl last`, `wait` and `run`.
///
/// Two kinds of pane, two kinds of answer. A pane `run` started runs one
/// program in place of a shell: its result is the process's own -- the exit
/// status Tako collects when it ends -- and what the pane shows. In a shell's
/// pane, a command is what the shell marked (OSC 133), named by its id in an
/// engine generation (`ref`, "ID@EPOCH"), and its output is the rows it owns;
/// nothing is guessed from the screen.
@MainActor
enum ControlCommand {
    /// Lines of output an answer carries unless asked for others.
    static let defaultLines = 200
    /// Most bytes of output an answer carries.
    static let maxBytes = 512 * 1024
    /// Longest wait asked for, in seconds: a week.
    static let maxTimeout: TimeInterval = 7 * 24 * 3600
    /// How often a wait looks again.
    static let pollInterval: TimeInterval = 0.25

    // MARK: arguments

    static func lines(_ args: [String: JSON]) throws -> Int {
        args["lines"] == nil ? defaultLines : min(try ControlInput.lines(args), 100_000)
    }

    static func timeout(_ args: [String: JSON]) throws -> TimeInterval? {
        switch args["timeout"] {
        case nil, .null?: return nil
        case .number(let n)? where n.isFinite && n >= 0 && n <= maxTimeout: return n
        default: throw ControlError(.invalid, "\"timeout\" must be seconds from 0 to \(Int(maxTimeout))")
        }
    }

    /// "ID@EPOCH", as `last` gives it.
    static func ref(_ args: [String: JSON]) throws -> (id: UInt64, epoch: UInt64)? {
        guard let raw = args["command"] else { return nil }
        let parts = raw.string?.split(separator: "@")
        guard let parts, parts.count == 2, let id = UInt64(parts[0]), let epoch = UInt64(parts[1]) else {
            throw ControlError(.invalid, "\"command\" must be ID@EPOCH, as last reports it")
        }
        return (id, epoch)
    }

    // MARK: last

    static func last(_ surface: Tako.SurfaceView, args: [String: JSON],
                     reply: @escaping @Sendable (ControlResponse) -> Void) throws {
        guard !SecureInput.shared.isSecure(for: surface) && !surface.isSecureInput else {
            throw ControlError(.disabled, "secure-input panes cannot be read")
        }
        let lines = try lines(args)
        let core = surface.core
        let id = surface.id.uuidString.lowercased()
        if let program = surface.runProgram {
            var result = process(program: program, pty: surface.pty, core: core, lines: lines, note: surface.runEndNote)
            result["id"] = .string(id)
            return reply(.ok(result))
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let found = core.lastCommand(maxLines: UInt32(lines), maxBytes: UInt32(maxBytes))
            let dur = found.flatMap { cmd in
                DispatchQueue.main.sync {
                    surface.commandDuration(id: cmd.command.id, epoch: cmd.command.epoch)
                }
            }
            var result = describe(found, duration: dur)
            result["id"] = .string(id)
            reply(.ok(result))
        }
    }

    // MARK: wait

    /// Waits for a run pane's program to exit, or for a shell's command --
    /// the one named by `command`, the running one, or with `next` the next
    /// one to start -- to end. Answers with `state`: `finished`, `abandoned`
    /// (a new prompt came first), `idle` (nothing running, nothing named),
    /// `gone` (the command's record or generation is no longer kept),
    /// `timeout` (still running). A wait on the request's own pane's running
    /// command, or on its next one, is refused: that command is the wait.
    static func wait(_ request: ControlRequest, _ surface: Tako.SurfaceView,
                     reply: @escaping @Sendable (ControlResponse) -> Void) throws {
        let lines = try lines(request.args)
        let timeout = try timeout(request.args)
        let named = try ref(request.args)
        let next = request.args["next"] == .bool(true)
        let core = surface.core
        let paneID = surface.id
        let idString = paneID.uuidString.lowercased()

        if let program = surface.runProgram {
            // A program run started, waiting on its own pane: it is the wait.
            if request.from == paneID {
                throw ControlError(.selfWait, "this request runs in the pane it would wait on: its program cannot end while it waits")
            }
            var exitedAt: Date?
            return poll(request, paneID, timeout: timeout, reply: reply) {
                guard let pty = surface.pty else { return nil }
                if pty.startError != nil {
                    var result = process(program: program, pty: pty, core: core, lines: lines, note: surface.runEndNote)
                    result["state"] = .string("failedToStart")
                    return result
                }
                // Ended when the process itself has; its last output may
                // still be on its way, until the terminal closes or briefly.
                guard pty.exitStatus != nil else { return nil }
                let at = exitedAt ?? Date()
                exitedAt = at
                guard !pty.alive || Date().timeIntervalSince(at) > 0.5 else { return nil }
                var result = process(program: program, pty: pty, core: core, lines: lines, note: surface.runEndNote)
                result["state"] = .string("finished")
                return result
            } onTimeout: {
                var result = process(program: program, pty: surface.pty, core: core, lines: lines, note: surface.runEndNote)
                result["state"] = .string("timeout")
                return result
            }
        }

        // Which command: named, or the running one, or (next) a newer one.
        let newest = core.lastCommand(maxLines: 0, maxBytes: 0)?.command
        // Next: the first command recorded after this one, whatever becomes of it.
        let baseline = core.newestCommandId() ?? 0
        var target: (id: UInt64, epoch: UInt64)? = named
        if target == nil, !next {
            guard let running = newest, running.running else {
                let found = core.lastCommand(maxLines: UInt32(lines), maxBytes: UInt32(maxBytes))
                let dur = found.flatMap { surface.commandDuration(id: $0.command.id, epoch: $0.command.epoch) }
                var result = describe(found, duration: dur)
                result["id"] = .string(idString)
                result["state"] = .string("idle")
                return reply(.ok(result))
            }
            target = (running.id, running.epoch)
        }
        if request.from == paneID, named == nil || named?.id == newest?.id && newest?.running == true {
            throw ControlError(.selfWait, "this request runs in the pane it would wait on: that command cannot end while it waits")
        }
        poll(request, paneID, timeout: timeout, reply: reply) {
            if target == nil {
                guard let first = core.firstCommandAfter(after: baseline) else { return nil }
                target = (first.id, first.epoch)
            }
            guard let (id, epoch) = target else { return nil }
            guard let found = core.commandOutput(id: id, epoch: epoch, maxLines: UInt32(lines), maxBytes: UInt32(maxBytes)) else {
                return ["id": .string(idString), "state": .string("gone"),
                        "command": .object(["ref": .string("\(id)@\(epoch)")])]
            }
            guard !found.command.running else { return nil }
            let dur = surface.commandDuration(id: id, epoch: epoch)
            var result = describe(found, duration: dur)
            result["id"] = .string(idString)
            result["state"] = .string(found.command.abandoned ? "abandoned" : "finished")
            return result
        } onTimeout: {
            var result: [String: JSON] = ["id": .string(idString), "state": .string("timeout")]
            if let (id, epoch) = target,
               let found = core.commandOutput(id: id, epoch: epoch, maxLines: UInt32(lines), maxBytes: UInt32(maxBytes)) {
                let dur = surface.commandDuration(id: id, epoch: epoch)
                result.merge(describe(found, duration: dur)) { _, new in new }
            }
            return result
        }
    }

    /// Calls `check` now and every `pollInterval` until it answers, the pane
    /// closes, the client goes, or `timeout` passes. Exactly one reply.
    private static func poll(_ request: ControlRequest, _ paneID: UUID, timeout: TimeInterval?,
                             reply: @escaping @Sendable (ControlResponse) -> Void,
                             check: @escaping () -> [String: JSON]?,
                             onTimeout: @escaping () -> [String: JSON]) {
        if let result = check() { return reply(.ok(result)) }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { timer in
            MainActor.assumeIsolated {
                func done(_ response: ControlResponse) {
                    timer.invalidate()
                    reply(response)
                }
                if request.clientGone() {
                    // Nobody to tell: stop waiting, free the connection.
                    done(.failure(ControlError(.timeout, "the client went away")))
                } else if !ControlCommands.panes().contains(where: { $0.surface.id == paneID }) {
                    done(.failure(ControlError(.notFound, "pane \(paneID.uuidString.lowercased()) closed while waiting")))
                } else if let result = check() {
                    done(.ok(result))
                } else if let deadline, Date() >= deadline {
                    done(.ok(onTimeout()))
                }
            }
        }
    }

    // MARK: run

    /// `run`: a new tab, or a split of the target, running `argv` in place
    /// of a shell; with `wait`, answered once the program exits.
    static func run(_ request: ControlRequest, beside surface: Tako.SurfaceView,
                    reply: @escaping @Sendable (ControlResponse) -> Void) throws {
        guard case .array? = request.args["argv"] else {
            throw ControlError(.invalid, "\"argv\" must be a non-empty list of strings")
        }
        _ = try lines(request.args)
        _ = try timeout(request.args)
        let pane: Tako.SurfaceView
        if case .string = request.args["split"] {
            var args = request.args
            args["direction"] = request.args["split"]
            pane = try ControlLayout.split(surface, args: args, client: request.client)
        } else {
            pane = try ControlLayout.newTab(beside: surface, args: request.args, client: request.client)
        }
        guard request.args["wait"] == .bool(true) else {
            return reply(.ok(["id": .string(pane.id.uuidString.lowercased())]))
        }
        try wait(request, pane, reply: reply)
    }

    // MARK: answers

    /// A run pane's program: its argv, whether it runs, how it ended, and
    /// the last lines the pane shows.
    static func process(program: [String], pty: PTY?, core: TakoCore, lines: Int, note: String?) -> [String: JSON] {
        let tail = core.textTail(maxLines: UInt32(lines) + 2, maxBytes: UInt32(maxBytes))
        let started = pty?.startError == nil
        let running = started && pty?.exitStatus == nil
        // The line Tako wrote when the program ended is not its output:
        // that exact line, the last one written, and the blank before it.
        var outputLines = tail.text.components(separatedBy: "\n")
        while outputLines.last?.isEmpty == true { outputLines.removeLast() }
        if let note, outputLines.last == note {
            outputLines.removeLast()
            if outputLines.last?.isEmpty == true { outputLines.removeLast() }
        }
        let kept = outputLines.suffix(lines)
        return [
            "process": .object([
                "argv": .array(program.map(JSON.string)),
                "running": .bool(running),
                "exitCode": running || !started ? .null : (pty?.exitStatus.map { .number(Double($0)) } ?? .null),
                "startError": pty?.startError.map { .string(String(cString: strerror($0))) } ?? .null,
            ]),
            "output": .string(kept.joined(separator: "\n")),
            "lines": .number(Double(kept.count)),
            "truncated": .bool(tail.truncated),
            "more": .bool(tail.more || outputLines.count > kept.count),
        ]
    }

    /// A shell command as JSON: `command` (null when the shell marked none),
    /// with `ref` to wait on it, its `output`, and optional elapsed duration (E10).
    nonisolated static func describe(_ found: FfiCommandOutput?, duration: TimeInterval? = nil) -> [String: JSON] {
        guard let found else {
            return ["command": .null, "output": .string(""), "lines": .number(0),
                    "truncated": .bool(false), "more": .bool(false), "incomplete": .bool(false)]
        }
        let info = found.command
        var command: [String: JSON] = [
            "ref": .string("\(info.id)@\(info.epoch)"),
            "input": info.input.map(JSON.string) ?? .null,
            "cwd": info.cwd.map { .string(path(fromReported: $0)) } ?? .null,
            "running": .bool(info.running),
            "finished": .bool(info.finished),
            "abandoned": .bool(info.abandoned),
            "exitCode": info.exitCode.map { .number(Double($0)) } ?? .null,
        ]
        if let started = info.startedAtMs { command["startedAt"] = .number(Double(started)) }
        if let duration {
            command["duration"] = .number(duration)
            command["durationMs"] = .number((duration * 1000.0).rounded())
        }
        var result: [String: JSON] = [
            "command": .object(command),
            "output": .string(found.output),
            "lines": .number(Double(found.lines)),
            "truncated": .bool(found.truncated),
            "more": .bool(found.more),
            "incomplete": .bool(found.incomplete),
        ]
        if let duration {
            result["duration"] = .number(duration)
            result["durationMs"] = .number((duration * 1000.0).rounded())
        }
        return result
    }

    /// A directory as the shell reported it (OSC 7: a `file://` URL) as a
    /// path; anything else as it came.
    nonisolated static func path(fromReported reported: String) -> String {
        if let url = URL(string: reported), url.scheme == "file" { return url.path }
        return reported
    }
}
