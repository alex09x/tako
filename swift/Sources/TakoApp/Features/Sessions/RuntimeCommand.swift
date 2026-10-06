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
        return result.output.split(separator: "\n").contains { $0.split(separator: "\t").first == "name=\(name)" }
    }
}
