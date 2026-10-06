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

/// A barrier's caller needs two different answers, and they arrive at
/// different times: "the engine has done it" (which releases the caller
/// from its wait) and "Main has been told about it" (which is where the
/// caller's synchronous obligation ends). This is the second one.
protocol BarrierPublication: AnyObject {
    var isPublished: Bool { get }
    func markPublished()
}

/// A pending ordered import: the blob to apply and the caller waiting on
/// the barrier.
final class ImportRequest: BarrierPublication, @unchecked Sendable {
    let blob: Data
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var outcome: Result<TerminalCheckpointRestore, Error>?
    private var published = false

    init(blob: Data) {
        self.blob = blob
    }

    var isPublished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    /// Called on Main, the instant this import's restore has been handed
    /// to the host's handler.
    func markPublished() {
        lock.lock()
        published = true
        lock.unlock()
    }

    /// First completion wins, so a shutdown racing the barrier cannot
    /// double-signal or overwrite a real result.
    func complete(_ result: Result<TerminalCheckpointRestore, Error>) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = result
        lock.unlock()
        done.signal()
    }

    func wait() throws -> TerminalCheckpointRestore {
        done.wait()
        lock.lock()
        let result = outcome
        lock.unlock()
        switch result {
        case .success(let restore): return restore
        case .failure(let error): throw error
        case nil: throw TerminalCheckpointImportError.shutDown
        }
    }
}

/// A pending ordered resize: the geometry to adopt and the caller waiting
/// on the barrier.
final class ResizeRequest: BarrierPublication, @unchecked Sendable {
    let cols: Int
    let rows: Int
    private let lock = NSLock()
    private let done = DispatchSemaphore(value: 0)
    private var completed = false
    private var published = false

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
    }

    var isPublished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return published
    }

    /// Called on Main, the instant this resize has been handed to the
    /// host's handler.
    func markPublished() {
        lock.lock()
        published = true
        lock.unlock()
    }

    /// First completion wins, so a shutdown racing the barrier cannot
    /// double-signal.
    func complete() {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        done.signal()
    }

    func wait() { done.wait() }
}

/// One FIFO for everything the engine is driven by, bytes and barriers
/// alike.
enum PendingWork {
    case bytes(Data)
    case importCheckpoint(ImportRequest)
    case resize(ResizeRequest)
}

/// What Main is owed, in the order the parser produced it.
enum PendingApplication {
    case outcome(FfiFeedOutcome)
    case restored(TerminalCheckpointRestore, ImportRequest)
    case rejectedImport(ImportRequest)
    case resized(cols: Int, rows: Int, request: ResizeRequest)
}
