import Foundation
import XCTest
@testable import TakoCoreUI

final class PTYDeliveryPumpTests: XCTestCase {
    func testPumpImmediateExitWhenFirstReadReturnsNil() {
        let queue = DispatchQueue(label: "test.target.queue")
        let exitExpectation = expectation(description: "onExit called")
        var dataReceived: [Data] = []

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: { nil },
                readNextIfAvailable: nil,
                onData: { data in dataReceived.append(data) },
                onExit: { exitExpectation.fulfill() },
                targetQueue: queue
            )
        }

        wait(for: [exitExpectation], timeout: 5.0)
        XCTAssertTrue(dataReceived.isEmpty)
    }

    func testPumpImmediateExitWhenFirstReadReturnsEmptyData() {
        let queue = DispatchQueue(label: "test.target.queue")
        let exitExpectation = expectation(description: "onExit called")
        var dataReceived: [Data] = []

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: { Data() },
                readNextIfAvailable: nil,
                onData: { data in dataReceived.append(data) },
                onExit: { exitExpectation.fulfill() },
                targetQueue: queue
            )
        }

        wait(for: [exitExpectation], timeout: 5.0)
        XCTAssertTrue(dataReceived.isEmpty)
    }

    func testPumpSingleBatchDeliveryAndExit() {
        let queue = DispatchQueue(label: "test.target.queue")
        let exitExpectation = expectation(description: "onExit called")
        var delivered: [Data] = []
        var reads: [Data?] = [Data("chunk1".utf8), nil]

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    reads.isEmpty ? nil : reads.removeFirst()
                },
                readNextIfAvailable: nil,
                onData: { data in delivered.append(data) },
                onExit: { exitExpectation.fulfill() },
                targetQueue: queue
            )
        }

        wait(for: [exitExpectation], timeout: 5.0)
        XCTAssertEqual(delivered, [Data("chunk1".utf8)])
    }

    func testPumpCoalescingWithoutReadNextIfAvailable() {
        let queue = DispatchQueue(label: "test.target.queue")
        let exitExpectation = expectation(description: "onExit called")
        var delivered: [Data] = []

        let holdCallback = DispatchSemaphore(value: 0)
        let unblockCallback = DispatchSemaphore(value: 0)

        var reads: [Data?] = [
            Data("batch1".utf8),
            Data("batch2_part1".utf8),
            Data("batch2_part2".utf8),
            nil,
            nil
        ]
        var readLock = NSLock()

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    readLock.lock()
                    defer { readLock.unlock() }
                    if reads.isEmpty { return nil }
                    let item = reads.removeFirst()
                    if item == Data("batch2_part2".utf8) {
                        unblockCallback.signal()
                    }
                    return item
                },
                readNextIfAvailable: nil,
                onData: { data in
                    delivered.append(data)
                    if data == Data("batch1".utf8) {
                        holdCallback.signal()
                        unblockCallback.wait()
                    }
                },
                onExit: { exitExpectation.fulfill() },
                targetQueue: queue
            )
        }

        // Wait for first callback to start
        holdCallback.wait()
        wait(for: [exitExpectation], timeout: 5.0)

        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered[0], Data("batch1".utf8))
        XCTAssertEqual(delivered[1], Data("batch2_part1".utf8) + Data("batch2_part2".utf8))
    }

    func testPumpCoalescingWithReadNextIfAvailable() {
        let queue = DispatchQueue(label: "test.target.queue")
        let exitExpectation = expectation(description: "onExit called")
        var delivered: [Data] = []

        let holdCallback = DispatchSemaphore(value: 0)
        let unblockCallback = DispatchSemaphore(value: 0)

        var blockingReads: [Data?] = [
            Data("chunk1".utf8),
            Data("chunk2".utf8),
            nil
        ]
        var availableReads: [Data?] = [
            Data("chunk3".utf8),
            nil
        ]
        let lock = NSLock()

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    lock.lock()
                    defer { lock.unlock() }
                    return blockingReads.isEmpty ? nil : blockingReads.removeFirst()
                },
                readNextIfAvailable: {
                    lock.lock()
                    defer { lock.unlock() }
                    if availableReads.isEmpty { return nil }
                    let item = availableReads.removeFirst()
                    unblockCallback.signal()
                    return item
                },
                onData: { data in
                    delivered.append(data)
                    if data == Data("chunk1".utf8) {
                        holdCallback.signal()
                        unblockCallback.wait()
                    }
                },
                onExit: { exitExpectation.fulfill() },
                targetQueue: queue
            )
        }

        holdCallback.wait()
        wait(for: [exitExpectation], timeout: 5.0)

        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered[0], Data("chunk1".utf8))
        XCTAssertEqual(delivered[1], Data("chunk2".utf8) + Data("chunk3".utf8))
    }

    func testPumpFastCallbackKernelDrain() {
        let queue = DispatchQueue(label: "test.target.queue")
        let exitExpectation = expectation(description: "onExit called")
        var delivered: [Data] = []

        var blockingReads: [Data?] = [
            Data("c1".utf8),
            Data("c2".utf8),
            nil
        ]
        var availableReads: [Data?] = [
            Data("drained".utf8),
            nil,
            nil
        ]
        let lock = NSLock()

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    lock.lock()
                    defer { lock.unlock() }
                    return blockingReads.isEmpty ? nil : blockingReads.removeFirst()
                },
                readNextIfAvailable: {
                    lock.lock()
                    defer { lock.unlock() }
                    return availableReads.isEmpty ? nil : availableReads.removeFirst()
                },
                onData: { data in
                    delivered.append(data)
                },
                onExit: { exitExpectation.fulfill() },
                targetQueue: queue
            )
        }

        wait(for: [exitExpectation], timeout: 5.0)
        XCTAssertFalse(delivered.isEmpty)
        XCTAssertEqual(delivered[0], Data("c1".utf8))
    }

    func testPumpMaxBufferedBytesCap() {
        let queue = DispatchQueue(label: "test.target.queue")
        let exitExpectation = expectation(description: "onExit called")
        var delivered: [Data] = []

        var blockingReads: [Data?] = [
            Data("first".utf8),
            Data("12345".utf8),
            nil
        ]
        var availableReads: [Data?] = [
            Data("67890".utf8),
            Data("extra".utf8),
            nil
        ]
        let lock = NSLock()

        let hold = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    lock.lock()
                    defer { lock.unlock() }
                    return blockingReads.isEmpty ? nil : blockingReads.removeFirst()
                },
                readNextIfAvailable: {
                    lock.lock()
                    defer { lock.unlock() }
                    if availableReads.isEmpty { return nil }
                    let item = availableReads.removeFirst()
                    resume.signal()
                    return item
                },
                onData: { data in
                    delivered.append(data)
                    if data == Data("first".utf8) {
                        hold.signal()
                        resume.wait()
                    }
                },
                onExit: { exitExpectation.fulfill() },
                targetQueue: queue,
                maxBufferedBytes: 8
            )
        }

        hold.wait()
        wait(for: [exitExpectation], timeout: 5.0)

        XCTAssertGreaterThanOrEqual(delivered.count, 2)
        XCTAssertEqual(delivered[0], Data("first".utf8))
    }

    func testPumpUInt8Overload() {
        let queue = DispatchQueue(label: "test.target.queue")
        let exitExpectation = expectation(description: "onExit called")
        var delivered: [[UInt8]] = []

        var reads: [[UInt8]?] = [
            [1, 2, 3],
            [4, 5, 6],
            nil
        ]
        var available: [[UInt8]?] = [
            [7, 8],
            nil
        ]
        let lock = NSLock()

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    lock.lock()
                    defer { lock.unlock() }
                    return reads.isEmpty ? nil : reads.removeFirst()
                },
                readNextIfAvailable: {
                    lock.lock()
                    defer { lock.unlock() }
                    return available.isEmpty ? nil : available.removeFirst()
                },
                onData: { bytes in
                    delivered.append(bytes)
                },
                onExit: { exitExpectation.fulfill() },
                targetQueue: queue
            )
        }

        wait(for: [exitExpectation], timeout: 5.0)
        XCTAssertFalse(delivered.isEmpty)
        XCTAssertEqual(delivered[0], [1, 2, 3])
    }

    func testPumpUInt8OverloadWithoutReadNextIfAvailable() {
        let queue = DispatchQueue(label: "test.target.queue")
        let exitExpectation = expectation(description: "onExit called")
        var delivered: [[UInt8]] = []

        var reads: [[UInt8]?] = [
            [42],
            nil
        ]
        let lock = NSLock()

        DispatchQueue.global().async {
            PTYDeliveryPump.pump(
                readNext: {
                    lock.lock()
                    defer { lock.unlock() }
                    return reads.isEmpty ? nil : reads.removeFirst()
                },
                readNextIfAvailable: nil,
                onData: { bytes in
                    delivered.append(bytes)
                },
                onExit: { exitExpectation.fulfill() },
                targetQueue: queue
            )
        }

        wait(for: [exitExpectation], timeout: 5.0)
        XCTAssertEqual(delivered, [[42]])
    }
}
