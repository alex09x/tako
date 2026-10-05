import Darwin
import Foundation

/// A subscriber streaming events over a control socket descriptor.
final class TerminalEventSubscriber: @unchecked Sendable {
    let id = UUID()
    let clientFD: Int32
    let paneFilter: String?
    let tabFilter: String?
    let workspaceFilter: String?
    let typeFilter: Set<String>?
    let onClose: @Sendable () -> Void

    private let lock = NSLock()
    private var queue: [Data] = []
    private var isWriting = false
    private var isClosed = false
    private var isDropping = false
    private var readSource: DispatchSourceRead?
    private let writeQueue = DispatchQueue(label: "tako.events.subscriber")

    /// Maximum events queued before a slow/stalled subscriber is dropped.
    static let maxQueueCapacity = 256
    /// Write timeout per event chunk before dropping.
    static let writeTimeoutSeconds: TimeInterval = 2.0

    init(
        clientFD: Int32,
        paneFilter: String?,
        tabFilter: String?,
        workspaceFilter: String?,
        typeFilter: Set<String>?,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.clientFD = clientFD
        self.paneFilter = paneFilter
        self.tabFilter = tabFilter
        self.workspaceFilter = workspaceFilter
        self.typeFilter = typeFilter
        self.onClose = onClose
    }

    /// Starts monitoring the client file descriptor for EOF / disconnect.
    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: clientFD, queue: writeQueue)
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            var byte: UInt8 = 0
            let n = recv(self.clientFD, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if n == 0 || (n < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                self.closeSubscriber()
            } else if n > 0 {
                // If client erroneously sends data over the events stream, drain and discard it
                var discard = [UInt8](repeating: 0, count: 1024)
                _ = read(self.clientFD, &discard, discard.count)
            }
        }
        let closeHandler = self.onClose
        source.setCancelHandler {
            closeHandler()
        }
        source.resume()

        lock.lock()
        if isClosed {
            lock.unlock()
            source.cancel()
        } else {
            self.readSource = source
            lock.unlock()
        }
    }

    /// Enqueues event data. Returns false if subscriber had to be dropped due to queue overflow.
    func enqueue(_ data: Data) -> Bool {
        let shouldSchedule: Bool
        let overflow: Bool

        lock.lock()
        if isClosed || isDropping {
            lock.unlock()
            return false
        }
        if queue.count >= Self.maxQueueCapacity {
            isDropping = true
            overflow = true
            shouldSchedule = false
        } else {
            queue.append(data)
            overflow = false
            shouldSchedule = !isWriting
            if shouldSchedule {
                isWriting = true
            }
        }
        lock.unlock()

        if overflow {
            writeQueue.async { [weak self] in
                self?.dropSlowSubscriber()
            }
            return false
        }

        if shouldSchedule {
            writeQueue.async { [weak self] in
                self?.pumpQueue()
            }
        }
        return true
    }

    private func pumpQueue() {
        while true {
            var chunk: Data?
            lock.lock()
            if isClosed {
                isWriting = false
                lock.unlock()
                return
            }
            if isDropping {
                isWriting = false
                lock.unlock()
                dropSlowSubscriber()
                return
            }
            if queue.isEmpty {
                isWriting = false
                lock.unlock()
                return
            }
            chunk = queue.removeFirst()
            lock.unlock()

            guard let data = chunk else { break }

            if !writeChunk(data) {
                // Socket error or write timeout: drop stalled subscriber
                dropSlowSubscriber()
                return
            }
        }
    }

    private func writeChunk(_ data: Data) -> Bool {
        let deadline = DispatchTime.now() + Self.writeTimeoutSeconds
        return data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                var abort = false
                lock.lock()
                if isClosed || isDropping {
                    abort = true
                }
                lock.unlock()
                if abort {
                    return false
                }
                if DispatchTime.now() > deadline {
                    return false
                }
                let n = write(clientFD, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 {
                    offset += n
                } else if n < 0 && errno == EINTR {
                    continue
                } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    var p = pollfd(fd: clientFD, events: Int16(POLLOUT), revents: 0)
                    let pollRes = poll(&p, 1, 100)
                    if pollRes <= 0 {
                        if pollRes < 0 && errno == EINTR { continue }
                        return false
                    }
                } else {
                    return false
                }
            }
            return true
        }
    }

    private func dropSlowSubscriber() {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isDropping = true
        lock.unlock()

        let msg = "{\"ok\":false,\"error\":{\"code\":\"dropped\",\"message\":\"slow subscriber dropped: send buffer full\"}}\n"
        _ = msg.withCString { ptr in
            var p = pollfd(fd: clientFD, events: Int16(POLLOUT), revents: 0)
            _ = poll(&p, 1, 50)
            _ = write(clientFD, ptr, strlen(ptr))
        }
        closeSubscriber()
    }

    func closeSubscriber() {
        let source: DispatchSourceRead?
        let shouldCallOnCloseDirectly: Bool

        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        isDropping = true
        queue.removeAll()
        source = readSource
        readSource = nil
        shouldCallOnCloseDirectly = (source == nil)
        lock.unlock()

        TerminalEventHub.shared.removeSubscriber(id: id)
        if let source = source {
            source.cancel()
        } else if shouldCallOnCloseDirectly {
            onClose()
        }
    }
}

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
