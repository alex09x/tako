import XCTest
import Darwin
@testable import Tako

final class TerminalEventStreamTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TerminalEventHub.shared.reset()
    }

    override func tearDown() {
        TerminalEventHub.shared.reset()
        super.tearDown()
    }

    func testTerminalEventEncoding() throws {
        let event = TerminalEvent(
            cursor: 42,
            timestamp: 1700000000.5,
            type: "command_start",
            pane: "ABCD-1234",
            tab: "tab-1",
            window: "win-1",
            workspace: "default",
            payload: [
                "command": .string("cargo test"),
                "cwd": .string("/tmp/project")
            ]
        )

        let data = event.encoded()
        guard let line = String(data: data, encoding: .utf8) else {
            XCTFail("Failed to decode data to UTF-8")
            return
        }

        XCTAssertTrue(line.hasSuffix("\n"), "Event line must end with newline")
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(json)
        XCTAssertEqual(json?["cursor"] as? Int, 42)
        XCTAssertEqual(json?["type"] as? String, "command_start")
        XCTAssertEqual(json?["pane"] as? String, "abcd-1234")
        XCTAssertEqual(json?["tab"] as? String, "tab-1")
        XCTAssertEqual(json?["window"] as? String, "win-1")
        XCTAssertEqual(json?["workspace"] as? String, "default")
        XCTAssertEqual(json?["command"] as? String, "cargo test")
        XCTAssertEqual(json?["cwd"] as? String, "/tmp/project")

        let dataDict = json?["data"] as? [String: Any]
        XCTAssertEqual(dataDict?["command"] as? String, "cargo test")
        XCTAssertEqual(dataDict?["cwd"] as? String, "/tmp/project")
    }

    func testTerminalEventFilterMatching() {
        let event = TerminalEvent(
            cursor: 1,
            type: "command_start",
            pane: "pane-123456",
            tab: "tab-main",
            workspace: "default",
            payload: [:]
        )

        // Matches everything when no filters
        XCTAssertTrue(event.matches(paneFilter: nil, tabFilter: nil, workspaceFilter: nil, typeFilter: nil))

        // Type filter
        XCTAssertTrue(event.matches(paneFilter: nil, tabFilter: nil, workspaceFilter: nil, typeFilter: ["command_start"]))
        XCTAssertTrue(event.matches(paneFilter: nil, tabFilter: nil, workspaceFilter: nil, typeFilter: ["COMMAND_START"]))
        XCTAssertFalse(event.matches(paneFilter: nil, tabFilter: nil, workspaceFilter: nil, typeFilter: ["command_end"]))

        // Pane filter (exact and prefix)
        XCTAssertTrue(event.matches(paneFilter: "pane-123456", tabFilter: nil, workspaceFilter: nil, typeFilter: nil))
        XCTAssertTrue(event.matches(paneFilter: "PANE-123", tabFilter: nil, workspaceFilter: nil, typeFilter: nil))
        XCTAssertFalse(event.matches(paneFilter: "other-pane", tabFilter: nil, workspaceFilter: nil, typeFilter: nil))

        // Tab filter
        XCTAssertTrue(event.matches(paneFilter: nil, tabFilter: "tab-main", workspaceFilter: nil, typeFilter: nil))
        XCTAssertTrue(event.matches(paneFilter: nil, tabFilter: "tab-", workspaceFilter: nil, typeFilter: nil))
        XCTAssertFalse(event.matches(paneFilter: nil, tabFilter: "tab-secondary", workspaceFilter: nil, typeFilter: nil))

        // Workspace filter
        XCTAssertTrue(event.matches(paneFilter: nil, tabFilter: nil, workspaceFilter: "default", typeFilter: nil))
        XCTAssertTrue(event.matches(paneFilter: nil, tabFilter: nil, workspaceFilter: "DEFAULT", typeFilter: nil))
        XCTAssertFalse(event.matches(paneFilter: nil, tabFilter: nil, workspaceFilter: "prod", typeFilter: nil))
    }

    func testRingBufferCursorMonotonicityAndCapacity() {
        let hub = TerminalEventHub.shared

        // Publish 5,010 events
        for i in 1...5_010 {
            hub.publish(type: "progress", payload: ["step": .number(Double(i))])
        }

        XCTAssertEqual(hub.newestCursor, 5_010)
        // Bounded capacity is 5,000; oldest cursor should be 5010 - 5000 + 1 = 11
        XCTAssertEqual(hub.oldestCursor, 11)
    }

    func testSubscribeWithExpiredCursorThrowsError() throws {
        let hub = TerminalEventHub.shared

        for _ in 1...5_010 {
            hub.publish(type: "status")
        }

        var sv: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv), 0)
        defer {
            close(sv[0])
            close(sv[1])
        }

        // Requesting cursor 5 when oldest available is 11 must throw expired error
        XCTAssertThrowsError(
            try hub.subscribe(
                clientFD: sv[0],
                args: ["cursor": .number(5)],
                onClose: {}
            )
        ) { error in
            guard let ctrlErr = error as? ControlError else {
                XCTFail("Expected ControlError, got \(error)")
                return
            }
            XCTAssertTrue(ctrlErr.message.contains("expired"))
            XCTAssertTrue(ctrlErr.message.contains("oldest available cursor is 11"))
        }
    }

    func testSubscribeReplaysMissedEventsFromValidCursor() throws {
        let hub = TerminalEventHub.shared

        for i in 1...10 {
            hub.publish(type: i % 2 == 0 ? "command_start" : "command_end", payload: ["index": .number(Double(i))])
        }

        var sv: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv), 0)
        defer {
            close(sv[0])
            close(sv[1])
        }

        let subscriber = try hub.subscribe(
            clientFD: sv[0],
            args: [
                "cursor": .number(6),
                "type": .string("command_start")
            ],
            onClose: {}
        )

        // Events with cursor > 6 and type "command_start" are cursor 8 and 10
        let exp = expectation(description: "Replayed events read")
        DispatchQueue.global().async {
            var lines: [String] = []
            var buf = [UInt8](repeating: 0, count: 4096)
            while lines.count < 2 {
                let n = read(sv[1], &buf, buf.count)
                if n <= 0 { break }
                let str = String(decoding: buf[0..<n], as: UTF8.self)
                lines.append(contentsOf: str.split(separator: "\n").map(String.init))
            }
            XCTAssertGreaterThanOrEqual(lines.count, 2)
            XCTAssertTrue(lines[0].contains("\"cursor\":8"))
            XCTAssertTrue(lines[1].contains("\"cursor\":10"))
            exp.fulfill()
        }

        wait(for: [exp], timeout: 3.0)
        subscriber.closeSubscriber()
    }

    func testSlowSubscriberIsDroppedWhenSendBufferOverflows() throws {
        let hub = TerminalEventHub.shared

        var sv: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv), 0)
        let serverWriteFD = sv[0]
        let clientReadFD = sv[1]
        defer {
            close(serverWriteFD)
            close(clientReadFD)
        }

        // Set 4KB send buffer on serverWriteFD
        var sndBuf: Int32 = 4096
        setsockopt(serverWriteFD, SOL_SOCKET, SO_SNDBUF, &sndBuf, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(serverWriteFD, F_SETFL, fcntl(serverWriteFD, F_GETFL) | O_NONBLOCK)

        // Set 1-second receive timeout on clientReadFD
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(clientReadFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let closeExp = expectation(description: "Subscriber onClose called")
        let subscriber = try hub.subscribe(
            clientFD: serverWriteFD,
            args: [:],
            onClose: {
                closeExp.fulfill()
            }
        )

        final class SafeState: @unchecked Sendable {
            var received = false
        }
        let state = SafeState()
        let readExp = expectation(description: "Read dropped message")

        DispatchQueue.global().async {
            var allRead = ""
            var buf = [UInt8](repeating: 0, count: 512)
            while true {
                let n = read(clientReadFD, &buf, buf.count)
                if n > 0 {
                    allRead += String(decoding: buf[0..<n], as: UTF8.self)
                    if allRead.contains("slow subscriber dropped") {
                        state.received = true
                        break
                    }
                } else if n <= 0 {
                    break
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
            readExp.fulfill()
        }

        // Rapidly enqueue large chunks faster than subscriber reads (queue limit is 256)
        let dummyData = Data(repeating: 0x41, count: 1024)
        var dropped = false
        for _ in 1...500 {
            if !subscriber.enqueue(dummyData) {
                dropped = true
                break
            }
        }

        XCTAssertTrue(dropped, "Subscriber should be dropped when queue overflows capacity")
        wait(for: [closeExp, readExp], timeout: 3.0)
        XCTAssertTrue(state.received, "Subscriber should have received dropped error message")
    }

    func testInvalidOrUnboundedCursorThrowsError() throws {
        let hub = TerminalEventHub.shared
        var sv: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv), 0)
        defer {
            close(sv[0])
            close(sv[1])
        }

        // Extremely large float exceeding UInt64.max must throw ControlError instead of trapping
        XCTAssertThrowsError(
            try hub.subscribe(
                clientFD: sv[0],
                args: ["cursor": .number(1e300)],
                onClose: {}
            )
        ) { error in
            XCTAssertTrue((error as? ControlError)?.message.contains("invalid cursor") ?? false)
        }

        // Negative number must throw
        XCTAssertThrowsError(
            try hub.subscribe(
                clientFD: sv[0],
                args: ["cursor": .number(-10)],
                onClose: {}
            )
        ) { error in
            XCTAssertTrue((error as? ControlError)?.message.contains("invalid cursor") ?? false)
        }

        // Non-integral float must throw
        XCTAssertThrowsError(
            try hub.subscribe(
                clientFD: sv[0],
                args: ["cursor": .number(3.14159)],
                onClose: {}
            )
        ) { error in
            XCTAssertTrue((error as? ControlError)?.message.contains("invalid cursor") ?? false)
        }

        // Invalid string must throw
        XCTAssertThrowsError(
            try hub.subscribe(
                clientFD: sv[0],
                args: ["cursor": .string("not-a-number")],
                onClose: {}
            )
        ) { error in
            XCTAssertTrue((error as? ControlError)?.message.contains("invalid cursor") ?? false)
        }

        // String exceeding UInt64.max must throw invalid cursor
        XCTAssertThrowsError(
            try hub.subscribe(
                clientFD: sv[0],
                args: ["cursor": .string("18446744073709551616")],
                onClose: {}
            )
        ) { error in
            XCTAssertTrue((error as? ControlError)?.message.contains("invalid cursor") ?? false)
        }

        // Maximum UInt64 cursor (18446744073709551615) must not trap in expiration check
        let subMax = try hub.subscribe(
            clientFD: sv[0],
            args: ["cursor": .string(String(UInt64.max))],
            onClose: {}
        )
        subMax.closeSubscriber()
    }

    func testIdleSubscriberIsClosedWhenClientDisconnects() throws {
        let hub = TerminalEventHub.shared

        var sv: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv), 0)
        let serverWriteFD = sv[0]
        let clientReadFD = sv[1]
        var clientClosed = false
        defer {
            close(serverWriteFD)
            if !clientClosed { close(clientReadFD) }
        }

        let closeExp = expectation(description: "Subscriber onClose called on client disconnect")
        let subscriber = try hub.subscribe(
            clientFD: serverWriteFD,
            args: [:],
            onClose: {
                closeExp.fulfill()
            }
        )

        XCTAssertTrue(hub.hasSubscriber(id: subscriber.id))

        // Disconnect client while stream is idle (no events emitted)
        clientClosed = true
        close(clientReadFD)

        wait(for: [closeExp], timeout: 3.0)
        XCTAssertFalse(hub.hasSubscriber(id: subscriber.id))
    }
}
