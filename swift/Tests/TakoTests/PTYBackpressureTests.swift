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
import Testing
@testable import Tako

struct PTYBackpressureTests {
    enum Event: Equatable {
        case data([UInt8])
        case exit
    }

    /// Proves that bounded read-ahead never creates concurrent onData callbacks.
    @Test func maxInFlightCallbackCountIsOne() {
        let queue = DispatchQueue(label: "test.pty.backpressure.queue")
        let chunks: [[UInt8]] = [
            Array("chunk-1".utf8),
            Array("chunk-2".utf8),
            Array("chunk-3".utf8),
            Array("chunk-4".utf8),
        ]

        let lock = NSLock()
        var readIndex = 0
        var deliveredBytes: [UInt8] = []
        var currentInFlight = 0
        var maxInFlight = 0

        let pumpGroup = DispatchGroup()
        pumpGroup.enter()

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    lock.withLock {
                        guard readIndex < chunks.count else { return nil }
                        let chunk = chunks[readIndex]
                        readIndex += 1
                        return chunk
                    }
                },
                onData: { chunk in
                    lock.withLock {
                        currentInFlight += 1
                        if currentInFlight > maxInFlight {
                            maxInFlight = currentInFlight
                        }
                    }

                    // Perform work
                    lock.withLock {
                        deliveredBytes.append(contentsOf: chunk)
                        currentInFlight -= 1
                    }
                },
                onExit: {
                    pumpGroup.leave()
                },
                targetQueue: queue
            )
        }

        pumpGroup.wait()

        lock.withLock {
            #expect(maxInFlight == 1)
            #expect(deliveredBytes == chunks.flatMap { $0 })
            #expect(readIndex == chunks.count)
        }
    }

    /// Proves that byte order is preserved across coalesced deliveries and
    /// onExit runs only after the final delivered byte.
    @Test func callbackOrderAndExitOrderingArePreserved() {
        let queue = DispatchQueue(label: "test.pty.order.queue")
        let chunks: [[UInt8]] = [
            [0x01, 0x02],
            [0x03, 0x04],
            [0x05, 0x06],
        ]

        let lock = NSLock()
        var readIndex = 0
        var events: [Event] = []

        let pumpGroup = DispatchGroup()
        pumpGroup.enter()

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    lock.withLock {
                        guard readIndex < chunks.count else { return nil }
                        let chunk = chunks[readIndex]
                        readIndex += 1
                        return chunk
                    }
                },
                onData: { chunk in
                    lock.withLock {
                        events.append(.data(chunk))
                    }
                },
                onExit: {
                    lock.withLock {
                        events.append(.exit)
                    }
                    pumpGroup.leave()
                },
                targetQueue: queue
            )
        }

        pumpGroup.wait()

        lock.withLock {
            #expect(events.last == .exit)
            let delivered = events.dropLast().flatMap { event -> [UInt8] in
                guard case let .data(bytes) = event else { return [] }
                return bytes
            }
            #expect(delivered == chunks.flatMap { $0 })
        }
    }

    /// Proves that chunks read while the target queue is busy are delivered
    /// as one bounded follow-up batch rather than one callback per read.
    @Test func coalescesReadAheadWhileCallbackIsBusy() {
        let queue = DispatchQueue(label: "test.pty.coalescing.queue")
        let chunks: [[UInt8]] = [[1], [2], [3], [4]]
        let releaseFirstCallback = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var readIndex = 0
        var deliveries: [[UInt8]] = []

        let pumpGroup = DispatchGroup()
        pumpGroup.enter()

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    lock.withLock {
                        guard readIndex < chunks.count else {
                            releaseFirstCallback.signal()
                            return nil
                        }
                        let chunk = chunks[readIndex]
                        readIndex += 1
                        if readIndex == chunks.count {
                            releaseFirstCallback.signal()
                        }
                        return chunk
                    }
                },
                onData: { chunk in
                    let isFirst = lock.withLock {
                        deliveries.append(chunk)
                        return deliveries.count == 1
                    }
                    if isFirst {
                        releaseFirstCallback.wait()
                    }
                },
                onExit: {
                    pumpGroup.leave()
                },
                targetQueue: queue,
                maxBufferedBytes: 3
            )
        }

        pumpGroup.wait()

        lock.withLock {
            #expect(deliveries == [[1], [2, 3, 4]])
        }
    }

    /// Proves that a fast callback still coalesces bytes already waiting in
    /// the PTY instead of falling back to one callback per kernel read.
    @Test func drainsImmediatelyAvailableBytesAfterFastCallback() {
        let queue = DispatchQueue(label: "test.pty.ready-drain.queue")
        let firstCallbackDone = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var readIndex = 0
        var readyReadCount = 0
        var deliveries: [[UInt8]] = []
        let chunks: [[UInt8]] = [[1], [2], [3], [4]]

        let pumpGroup = DispatchGroup()
        pumpGroup.enter()

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    let index = lock.withLock { () -> Int? in
                        guard readIndex < 2 else { return nil }
                        let current = readIndex
                        readIndex += 1
                        return current
                    }
                    guard let index else { return nil }
                    if index == 1 {
                        firstCallbackDone.wait()
                    }
                    return chunks[index]
                },
                readNextIfAvailable: {
                    lock.withLock {
                        readyReadCount += 1
                        guard readIndex < chunks.count else { return nil }
                        let chunk = chunks[readIndex]
                        readIndex += 1
                        return chunk
                    }
                },
                onData: { chunk in
                    lock.withLock { deliveries.append(chunk) }
                    if chunk == [1] {
                        firstCallbackDone.signal()
                    }
                },
                onExit: { pumpGroup.leave() },
                targetQueue: queue,
                maxBufferedBytes: 4
            )
        }

        pumpGroup.wait()

        lock.withLock {
            #expect(deliveries == [[1], [2, 3, 4]])
            #expect(readyReadCount == 3)
        }
    }

    /// Proves that stopping/terminating early unblocks pump execution cleanly without deadlocking.
    @Test func terminateAndCancellationSafety() {
        let queue = DispatchQueue(label: "test.pty.cancel.queue")
        let lock = NSLock()
        var alive = true
        var delivered: [[UInt8]] = []

        let pumpGroup = DispatchGroup()
        pumpGroup.enter()

        DispatchQueue.global().async {
            var counter: UInt8 = 0
            PTYDeliveryPump.pump(
                readNext: {
                    lock.withLock {
                        guard alive else { return nil }
                        counter += 1
                        if counter == 2 {
                            alive = false
                        }
                        return [counter]
                    }
                },
                onData: { chunk in
                    lock.withLock {
                        delivered.append(chunk)
                    }
                },
                onExit: {
                    pumpGroup.leave()
                },
                targetQueue: queue
            )
        }

        pumpGroup.wait()

        lock.withLock {
            #expect(delivered.flatMap { $0 } == [1, 2])
        }
    }


}
