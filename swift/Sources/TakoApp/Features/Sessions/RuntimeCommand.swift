/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

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
        return listing(result.output)[name] != nil
    }

    /// The process `zmx list` gives for this session: its shell. Nil when
    /// it cannot tell.
    static func sessionPID(_ runtime: URL, name: String, environment: [String: String]) -> pid_t? {
        guard let result = run(runtime, ["list"], environment: environment), result.status == 0 else { return nil }
        return listing(result.output)[name]?["pid"].flatMap { pid_t($0) }
    }

    /// `zmx list` as fields by session name. Every line starts with a
    /// marker -- `→ ` for the session the caller runs in, two spaces for the
    /// rest, even with no session in the environment -- and lists its
    /// fields as `key=value`, tab separated. Read without the marker, every
    /// name looked absent: a client that ended on its own was taken for its
    /// shell having exited, and the tab closed over a session still running.
    static func listing(_ output: String) -> [String: [String: String]] {
        var sessions: [String: [String: String]] = [:]
        for line in output.split(separator: "\n") {
            var fields: [String: String] = [:]
            for field in line.drop(while: { $0 == " " || $0 == "→" }).split(separator: "\t") {
                guard let eq = field.firstIndex(of: "=") else { continue }
                fields[String(field[..<eq])] = String(field[field.index(after: eq)...])
            }
            if let name = fields["name"] { sessions[name] = fields }
        }
        return sessions
    }

    enum ConditionalKillOutcome: Equatable {
        /// The daemon verified `tako-gen=<generation>` atomically and shut down.
        case killed
        /// The daemon or CLI refused the kill (generation mismatch, missing session,
        /// or an older daemon that does not support `KillIfLabel`).
        case refused(status: Int32)
        /// The helper process could not be run or timed out.
        case unreachable
    }

    /// CLI arguments for server-side conditional kill (`Tag.KillIfLabel`).
    static func killIfGenerationArguments(name: String, generation: String) -> [String] {
        ["kill", "--if-label", "tako-gen=\(generation)", name]
    }

    /// CLI arguments for attach-only with generation verification (`Tag.AttachIfLabel`,
    /// with single-socket fallback to `Tag.LabelGet` on older `0.8.x` daemons).
    /// Never creates a new daemon or unlinks a socket if the session is absent or unresponsive.
    static func attachOnlyIfGenerationArguments(name: String, generation: String, attempt: String? = nil) -> [String] {
        var args = ["attach", "--attach-only", "--if-label", "tako-gen=\(generation)"]
        if let attempt, !attempt.isEmpty {
            args.append(contentsOf: ["--labels", "tako-attempt=\(attempt)"])
        }
        args.append(name)
        return args
    }

    /// CLI arguments for create-only session launch (`zmx attach --create-only`).
    /// Atomically binds the session socket with initial labels before accepting clients;
    /// fails closed without attaching, mutating labels, or unlinking the socket if `name` already exists.
    static func createOnlyWithGenerationArguments(
        name: String,
        generation: String,
        attempt: String? = nil,
        command: [String] = []
    ) -> [String] {
        var labels = "tako-gen=\(generation)"
        if let attempt, !attempt.isEmpty {
            labels += " tako-attempt=\(attempt)"
        }
        var args = ["attach", "--create-only", "--labels", labels, name]
        args.append(contentsOf: command)
        return args
    }

    /// Ends `name` only if the running daemon atomically confirms `tako-gen=<generation>`.
    /// Fails closed against older daemons (which ignore `Tag.KillIfLabel` and time out)
    /// and against empty `name` or `generation`.
    static func killIfGeneration(
        _ runtime: URL,
        name: String,
        generation: String,
        environment: [String: String],
        timeout: TimeInterval = 3
    ) -> ConditionalKillOutcome {
        guard !name.isEmpty, !generation.isEmpty else { return .refused(status: -1) }
        guard let result = run(
            runtime,
            killIfGenerationArguments(name: name, generation: generation),
            environment: environment,
            timeout: timeout
        ) else {
            return .unreachable
        }
        if result.status == 0, result.output.contains("killed session \(name)") {
            return .killed
        }
        return .refused(status: result.status)
    }
}
