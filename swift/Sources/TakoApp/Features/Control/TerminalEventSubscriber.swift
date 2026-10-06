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
        queue.removeAll()
        lock.unlock()

        let msg = "{\"ok\":false,\"error\":{\"code\":\"dropped\",\"message\":\"slow subscriber dropped: send buffer full\"}}\n"
        msg.withCString { ptr in
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
