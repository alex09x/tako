import Foundation
import Testing
@testable import Tako

struct PTYBackpressureTests {
    private enum Event: Equatable {
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

    /// Proves that Data-based PTYDeliveryPump preserves maxInFlightCallbackCount == 1.
    @Test func dataPumpMaxInFlightCallbackCountIsOne() {
        let queue = DispatchQueue(label: "test.pty.data.backpressure.queue")
        let chunks: [Data] = [
            Data("chunk-1".utf8),
            Data("chunk-2".utf8),
            Data("chunk-3".utf8),
            Data("chunk-4".utf8),
        ]

        let lock = NSLock()
        var readIndex = 0
        var deliveredBytes = Data()
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

                    lock.withLock {
                        deliveredBytes.append(chunk)
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
            #expect(deliveredBytes == chunks.reduce(Data(), +))
            #expect(readIndex == chunks.count)
        }
    }

    /// Proves that Data-based PTYDeliveryPump coalesces read-ahead while callback is busy.
    @Test func dataPumpCoalescesReadAheadWhileCallbackIsBusy() {
        let queue = DispatchQueue(label: "test.pty.data.coalescing.queue")
        let chunks: [Data] = [Data([1]), Data([2]), Data([3]), Data([4])]
        let releaseFirstCallback = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var readIndex = 0
        var deliveries: [Data] = []

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
            #expect(deliveries == [Data([1]), Data([2, 3, 4])])
        }
    }

    /// Proves that the Surface architecture using a serial parser queue and
    /// main.sync bounded handoff does not run on Main, keeps at most one UI
    /// application outstanding, keeps batches/events ordered, ensures device
    /// replies precede later dependent batches, exits on cancellation, and
    /// never runs main.sync when already on Main.
    @Test @MainActor func surfaceDeliveryArchitecture() async {
        let parserQueue = DispatchQueue(label: "test.parser.queue")
        let lock = NSLock()
        var readIndex = 0
        let chunks: [Data] = [Data([1]), Data([2])]
        var events: [String] = []
        var maxUiOutstanding = 0
        var currentUiOutstanding = 0
        var mainSyncFromMainCount = 0
        var alive = true

        let pumpGroup = DispatchGroup()
        pumpGroup.enter()

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    lock.withLock {
                        guard alive else { return nil }
                        guard readIndex < chunks.count else { return nil }
                        let chunk = chunks[readIndex]
                        readIndex += 1
                        return chunk
                    }
                },
                onData: { chunk in
                    let isMain = Thread.isMainThread
                    lock.withLock {
                        events.append("parse:\(chunk.first!):onMain=\(isMain)")
                        currentUiOutstanding += 1
                        if currentUiOutstanding > maxUiOutstanding {
                            maxUiOutstanding = currentUiOutstanding
                        }
                    }

                    let apply = {
                        lock.withLock {
                            events.append("apply:\(chunk.first!)")
                            events.append("reply:\(chunk.first!)")
                            currentUiOutstanding -= 1
                            if chunk.first! == 2 {
                                alive = false // Cancel on chunk 2
                            }
                        }
                    }

                    if Thread.isMainThread {
                        lock.withLock { mainSyncFromMainCount += 1 }
                        apply()
                    } else {
                        DispatchQueue.main.sync {
                            apply()
                        }
                    }
                },
                onExit: {
                    lock.withLock { events.append("exit") }
                    pumpGroup.leave()
                },
                targetQueue: parserQueue
            )
        }

        // Wait without blocking the main actor
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                pumpGroup.wait()
                cont.resume()
            }
        }

        lock.withLock {
            #expect(mainSyncFromMainCount == 0)
            #expect(maxUiOutstanding <= 1)
            #expect(events == [
                "parse:1:onMain=false", "apply:1", "reply:1",
                "parse:2:onMain=false", "apply:2", "reply:2",
                "exit"
            ])
        }
    }

    /// The stall behind "press Enter and the prompt finally appears".
    ///
    /// Read-ahead accumulates bytes while the target queue is busy, and used
    /// to keep filling that buffer with a *blocking* read even when a
    /// non-blocking one was available. A stream that went quiet with
    /// something already accumulated left the pump sitting inside that read
    /// holding the bytes -- an interrupted `tail -f`'s last output and the
    /// shell prompt printed after it among them -- until the stream spoke
    /// again. Pressing Enter was what made it speak.
    ///
    /// Here the source offers two chunks and then goes silent for good, with
    /// a non-blocking read that reports the silence honestly. Both chunks
    /// have to arrive anyway.
    @Test func quietStreamDoesNotStrandAccumulatedBytes() {
        let queue = DispatchQueue(label: "test.pty.quiet")
        let chunks: [[UInt8]] = [Array("first".utf8), Array("prompt$ ".utf8)]

        let lock = NSLock()
        var readIndex = 0
        var delivered: [UInt8] = []
        let allDelivered = DispatchSemaphore(value: 0)
        // Blocks for the rest of the test once the chunks run out, the way a
        // real pty read does when nothing is writing to it.
        let silence = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    let chunk: [UInt8]? = lock.withLock {
                        guard readIndex < chunks.count else { return nil }
                        defer { readIndex += 1 }
                        return chunks[readIndex]
                    }
                    if let chunk { return chunk }
                    silence.wait()
                    return nil
                },
                readNextIfAvailable: {
                    lock.withLock {
                        guard readIndex < chunks.count else { return nil }
                        defer { readIndex += 1 }
                        return chunks[readIndex]
                    }
                },
                onData: { bytes in
                    let total = lock.withLock { () -> Int in
                        delivered.append(contentsOf: bytes)
                        return delivered.count
                    }
                    if total >= 13 { allDelivered.signal() }
                },
                onExit: {},
                targetQueue: queue
            )
        }

        let arrived = allDelivered.wait(timeout: .now() + 3) == .success
        silence.signal()

        #expect(arrived, "the pump held bytes until the stream spoke again")
        #expect(lock.withLock { delivered } == Array("firstprompt$ ".utf8))
    }
}
