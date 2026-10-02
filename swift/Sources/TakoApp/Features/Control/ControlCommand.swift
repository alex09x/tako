import AppKit

/// `takoctl last`, `wait` and `run`: what a pane's commands did, as the
/// shell marked them (OSC 133) -- never guessed from the screen.
@MainActor
enum ControlCommand {
    /// Most lines of output an answer carries unless asked for fewer.
    static let defaultLines = 200
    /// Most bytes of output an answer carries.
    static let maxBytes = 512 * 1024
    /// How often a wait checks that its pane is still there.
    static let pollInterval: TimeInterval = 0.25

    /// The pane's newest marked command and what it printed, read off the
    /// main thread.
    static func last(_ surface: Tako.SurfaceView, args: [String: JSON],
                     reply: @escaping @Sendable (ControlResponse) -> Void) {
        let lines = Int(args["lines"]?.number ?? Double(defaultLines))
        let core = surface.core
        let id = surface.id.uuidString.lowercased()
        DispatchQueue.global(qos: .userInitiated).async {
            var result = describe(core, lines: lines)
            result["id"] = .string(id)
            reply(.ok(result))
        }
    }

    /// Waits for the pane's running command to end -- or, with `next`, for
    /// the next command to end -- then answers as `last` does with `state`
    /// `finished`. `idle` at once when nothing runs and `next` is not set;
    /// `timeout` when `timeout` passes first (the command is left running).
    static func wait(_ surface: Tako.SurfaceView, next: Bool, timeout: TimeInterval?, lines: Int,
                     reply: @escaping @Sendable (ControlResponse) -> Void) {
        let id = surface.id
        let idString = id.uuidString.lowercased()
        let core = surface.core
        func answer(_ state: String) {
            DispatchQueue.global(qos: .userInitiated).async {
                var result = describe(core, lines: lines)
                result["id"] = .string(idString)
                result["state"] = .string(state)
                reply(.ok(result))
            }
        }
        if !next, !surface.isCommandRunning { return answer("idle") }

        let token = UUID()
        var done = false
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        var poll: Timer?
        func finish(_ act: () -> Void) {
            guard !done else { return }
            done = true
            poll?.invalidate()
            surface.commandEndObservers[token] = nil
            act()
        }
        surface.commandEndObservers[token] = { _ in
            // The engine has the record once the event is through; read on
            // the next turn so the output's last rows are in.
            DispatchQueue.main.async { finish { answer("finished") } }
        }
        poll = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { _ in
            MainActor.assumeIsolated {
                if !ControlCommands.panes().contains(where: { $0.surface.id == id }) {
                    finish { reply(.failure(ControlError(.notFound, "pane \(idString) closed while waiting"))) }
                } else if let deadline, Date() >= deadline {
                    finish { answer("timeout") }
                }
            }
        }
    }

    /// `run`: a new tab (or a split of the target, with `split`) in the
    /// given directory, the command typed into it, and -- with `wait` --
    /// the answer `wait` gives for it.
    static func run(beside surface: Tako.SurfaceView, args: [String: JSON],
                    reply: @escaping @Sendable (ControlResponse) -> Void) throws {
        let command = try ControlInput.text(args, "command")
        let pane: Tako.SurfaceView
        if case .string = args["split"] {
            var splitArgs = args
            splitArgs["direction"] = args["split"]
            pane = try ControlLayout.split(surface, args: splitArgs)
        } else {
            pane = try ControlLayout.newTab(beside: surface, args: args)
        }
        // Waiting starts before the command is typed, so a quick one
        // cannot end before anyone listens.
        if args["wait"] == .bool(true) {
            // The line is the one typed here, when the shell did not report
            // it (fish marks no command line).
            let filled: @Sendable (ControlResponse) -> Void = { response in
                guard case .ok(var result) = response, case .object(var info)? = result["command"],
                      info["input"] == .null else { return reply(response) }
                info["input"] = .string(command)
                result["command"] = .object(info)
                reply(.ok(result))
            }
            wait(pane, next: true, timeout: args["timeout"]?.number,
                 lines: Int(args["lines"]?.number ?? Double(defaultLines)), reply: filled)
            try ControlInput.send(pane, text: command, enter: true)
        } else {
            try ControlInput.send(pane, text: command, enter: true)
            reply(.ok(["id": .string(pane.id.uuidString.lowercased())]))
        }
    }

    /// The newest marked command as JSON: `command` (null when the shell
    /// marked none) and its `output`. Safe off the main thread.
    nonisolated static func describe(_ core: TakoCore, lines: Int) -> [String: JSON] {
        guard let last = core.lastCommand(maxLines: UInt32(clamping: max(lines, 0)), maxBytes: UInt32(maxBytes)) else {
            return ["command": .null, "output": .string(""), "lines": .number(0),
                    "truncated": .bool(false), "more": .bool(false)]
        }
        let info = last.command
        var command: [String: JSON] = [
            "input": info.input.map(JSON.string) ?? .null,
            "cwd": info.cwd.map { .string(path(fromReported: $0)) } ?? .null,
            "running": .bool(info.running),
            "finished": .bool(info.finished),
            "exitCode": info.exitCode.map { .number(Double($0)) } ?? .null,
        ]
        if let started = info.startedAtMs { command["startedAt"] = .number(Double(started)) }
        return [
            "command": .object(command),
            "output": .string(last.output),
            "lines": .number(Double(last.lines)),
            "truncated": .bool(last.truncated),
            "more": .bool(last.more),
        ]
    }

    /// A directory as the shell reported it (OSC 7: a `file://` URL) as a
    /// path; anything else as it came.
    nonisolated static func path(fromReported reported: String) -> String {
        if let url = URL(string: reported), url.scheme == "file" { return url.path }
        return reported
    }
}
