/*
 * tako — Host key prompt test clock
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation

@MainActor
final class HostKeyPromptTestClock {
    private var now: Duration = .zero
    private var cancelled = false
    private var pending: (deadline: Duration, continuation: CheckedContinuation<Void, Error>)?

    var isSleeping: Bool { pending != nil }

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        guard !cancelled else { throw CancellationError() }
        try await withCheckedThrowingContinuation { continuation in
            precondition(pending == nil)
            pending = (now + duration, continuation)
        }
    }

    func advance(by duration: Duration) {
        now += duration
        guard let pending, pending.deadline <= now else { return }
        self.pending = nil
        pending.continuation.resume()
    }

    func cancel() {
        cancelled = true
        let continuation = pending?.continuation
        pending = nil
        continuation?.resume(throwing: CancellationError())
    }
}
