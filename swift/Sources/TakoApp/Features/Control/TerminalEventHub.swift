/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Darwin
import Foundation

/// Central event hub managing the bounded event ring buffer and live subscribers.
final class TerminalEventHub: @unchecked Sendable {
    static let shared = TerminalEventHub()

    /// Maximum events kept in the replay ring buffer.
    static let ringBufferCapacity = 5_000

    private let lock = NSLock()
    private var buffer: [TerminalEvent] = []
    private var nextCursor: UInt64 = 1
    private var subscribers: [UUID: TerminalEventSubscriber] = [:]

    init() {}

    /// Clears all events and subscribers (useful for testing).
    func reset() {
        lock.lock()
        buffer.removeAll()
        nextCursor = 1
        let subs = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()

        for sub in subs {
            sub.closeSubscriber()
        }
    }

    /// The oldest cursor currently available in the ring buffer.
    var oldestCursor: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return buffer.first?.cursor ?? nextCursor
    }

    /// The newest cursor emitted so far.
    var newestCursor: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return buffer.last?.cursor ?? 0
    }

    /// Checks if a subscriber with given ID is currently registered.
    func hasSubscriber(id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return subscribers[id] != nil
    }

    /// Number of active subscribers.
    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribers.count
    }

    /// Publishes an event to the ring buffer and all matching subscribers.
    func publish(
        type: String,
        pane: String? = nil,
        tab: String? = nil,
        window: String? = nil,
        workspace: String? = "default",
        payload: [String: JSON] = [:]
    ) {
        let event: TerminalEvent
        let matchingSubs: [TerminalEventSubscriber]

        lock.lock()
        let cursor = nextCursor
        nextCursor += 1
        event = TerminalEvent(
            cursor: cursor,
            timestamp: Date().timeIntervalSince1970,
            type: type,
            pane: pane,
            tab: tab,
            window: window,
            workspace: workspace,
            payload: payload
        )

        buffer.append(event)
        if buffer.count > Self.ringBufferCapacity {
            buffer.removeFirst(buffer.count - Self.ringBufferCapacity)
        }

        matchingSubs = subscribers.values.filter { sub in
            event.matches(
                paneFilter: sub.paneFilter,
                tabFilter: sub.tabFilter,
                workspaceFilter: sub.workspaceFilter,
                typeFilter: sub.typeFilter
            )
        }
        lock.unlock()

        let data = event.encoded()
        for sub in matchingSubs {
            _ = sub.enqueue(data)
        }
    }

    /// Registers a new subscriber, replaying missed events if a valid cursor was specified.
    @discardableResult
    func subscribe(
        clientFD: Int32,
        args: [String: JSON],
        onClose: @escaping @Sendable () -> Void
    ) throws -> TerminalEventSubscriber {
        let paneFilter = args["pane"]?.string ?? args["target"]?.string
        let tabFilter = args["tab"]?.string
        let workspaceFilter = args["workspace"]?.string

        let typeFilter: Set<String>? = {
            if let arr = args["types"] ?? args["type"] {
                if case .array(let list) = arr {
                    return Set(list.compactMap { $0.string?.lowercased() })
                } else if case .string(let s) = arr {
                    let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                    return Set(parts)
                }
            }
            return nil
        }()

        let requestedCursor: UInt64?
        if let c = args["cursor"], c != .null {
            switch c {
            case .number(let n):
                guard n.isFinite, n >= 0, let val = UInt64(exactly: n) else {
                    throw ControlError(.invalid, "invalid cursor: expected non-negative integer <= \(UInt64.max)")
                }
                requestedCursor = val
            case .string(let s):
                guard let val = UInt64(s) else {
                    throw ControlError(.invalid, "invalid cursor: expected non-negative integer string")
                }
                requestedCursor = val
            default:
                throw ControlError(.invalid, "invalid cursor: expected integer or numeric string")
            }
        } else {
            requestedCursor = nil
        }

        var replayEvents: [TerminalEvent] = []

        lock.lock()
        if let req = requestedCursor {
            let earliest = buffer.first?.cursor ?? nextCursor
            if req < earliest && (earliest - req) > 1 {
                lock.unlock()
                throw ControlError(
                    .invalid,
                    "cursor \(req) expired; oldest available cursor is \(earliest)"
                )
            }
            replayEvents = buffer.filter { event in
                event.cursor > req && event.matches(
                    paneFilter: paneFilter,
                    tabFilter: tabFilter,
                    workspaceFilter: workspaceFilter,
                    typeFilter: typeFilter
                )
            }
        }

        let subscriber = TerminalEventSubscriber(
            clientFD: clientFD,
            paneFilter: paneFilter,
            tabFilter: tabFilter,
            workspaceFilter: workspaceFilter,
            typeFilter: typeFilter,
            onClose: onClose
        )
        subscribers[subscriber.id] = subscriber
        lock.unlock()

        // Monitor client socket for disconnect / EOF
        subscriber.start()

        // Enqueue replay backlog
        for event in replayEvents {
            if !subscriber.enqueue(event.encoded()) {
                break
            }
        }

        return subscriber
    }

    func removeSubscriber(id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }
}
