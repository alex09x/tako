import CryptoKit
import Darwin
import Foundation

/// The listening end of `takoctl`: a unix socket only this user can open.
///
/// Requests are read and answered on background threads; only the work a
/// request asks for runs on the main thread, through `handler`. Every stage
/// is bounded: connections at once, requests waiting for the main thread,
/// the time to send a request and to take its answer.
final class ControlServer: @unchecked Sendable {
    /// Connections served at once; more are answered `busy`.
    static let maxConnections = 32
    /// Requests waiting for, or running on, the main thread.
    static let maxMainBacklog = 64
    /// How long a client has to send its request, and to take the answer.
    static let readTimeout: TimeInterval = 5
    static let writeTimeout: TimeInterval = 10

    typealias Handler = @MainActor (ControlRequest, @escaping @Sendable (ControlResponse) -> Void) -> Void

    let path: String
    private let handler: Handler
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let acceptQueue = DispatchQueue(label: "tako.control.accept")
    private let lock = NSLock()
    private var connections = 0      // under lock
    private var mainBacklog = 0      // under lock
    /// The socket file this server made, to remove only that one on stop.
    private var boundInode: ino_t = 0
    /// `<path>.lock`, held exclusively for as long as this server listens.
    private var ownerLock: Int32 = -1

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    // MARK: - Where the socket lives

    /// The socket for the app with `bundleID`: in this user's private
    /// temporary directory (0700, owned by the user), named after the bundle
    /// id so each build of Tako has its own. The same for `takoctl`, which
    /// gets the path from `TAKO_SOCKET` inside a pane and works it out the
    /// same way outside one.
    static func socketPath(bundleID: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count) > 0 else {
            throw ControlError(.internalError, "no per-user temporary directory")
        }
        let dir = String(cString: buffer)
        let digest = SHA256.hash(data: Data(bundleID.utf8)).map { String(format: "%02x", $0) }.joined()
        let path = (dir as NSString).appendingPathComponent("tako-ctl-\(digest.prefix(12)).sock")
        try checkLength(path)
        return path
    }

    /// A unix socket path must fit `sockaddr_un.sun_path`, in bytes.
    static func checkLength(_ path: String) throws {
        let limit = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        guard path.utf8.count < limit else {
            throw ControlError(.internalError, "socket path is \(path.utf8.count) bytes; the limit is \(limit - 1)")
        }
    }

    /// The directory must be a real directory, this user's, closed to others.
    static func checkDirectory(_ dir: String) throws {
        var st = stat()
        guard lstat(dir, &st) == 0 else { throw ControlError(.internalError, "cannot stat \(dir)") }
        guard st.st_mode & S_IFMT == S_IFDIR else {
            throw ControlError(.internalError, "\(dir) is not a directory")
        }
        guard st.st_uid == getuid(), st.st_mode & 0o077 == 0 else {
            throw ControlError(.internalError, "\(dir) is not private to this user")
        }
    }

    // MARK: - Starting and stopping

    enum StartResult: Equatable {
        case listening
        /// Another copy of Tako already answers on this socket; it keeps it.
        case taken
    }

    /// Binds and starts accepting.
    ///
    /// Ownership is a lock, not a probe: whoever holds `<path>.lock` serves
    /// the socket, for as long as it runs. A copy that cannot take the lock
    /// leaves everything alone -- a live server that is merely slow to answer
    /// is never mistaken for a dead one. With the lock held, a socket file
    /// still there was left by a server that is gone, and only one that is
    /// this user's socket is removed.
    func start() throws -> StartResult {
        try Self.checkLength(path)
        try Self.checkDirectory((path as NSString).deletingLastPathComponent)

        let lockFD = open(path + ".lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw ControlError(.internalError, "cannot open the socket lock: \(errno)") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            let e = errno
            close(lockFD)
            if e == EWOULDBLOCK { return .taken }
            throw ControlError(.internalError, "cannot lock the socket: \(e)")
        }
        var started = false
        defer { if !started { close(lockFD) } }

        var st = stat()
        if lstat(path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFSOCK, st.st_uid == getuid() else {
                throw ControlError(.internalError, "\(path) exists and is not this user's socket")
            }
            unlink(path)
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError(.internalError, "socket: \(errno)") }
        var address = Self.address(path)
        // Created 0600 from the start: no window in which it is open to others.
        let previous = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previous)
        guard bound == 0 else {
            let e = errno
            close(fd)
            throw ControlError(.internalError, "bind: \(e)")
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            unlink(path)
            throw ControlError(.internalError, "listen: \(errno)")
        }
        if lstat(path, &st) == 0 { boundInode = st.st_ino }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listener = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
        ownerLock = lockFD
        started = true
        return .listening
    }

    /// Stops accepting and removes the socket file -- only if it is still the
    /// one this server bound.
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        var st = stat()
        if boundInode != 0, lstat(path, &st) == 0, st.st_ino == boundInode {
            unlink(path)
        }
        boundInode = 0
        // Released last: the next owner finds no socket of ours to clear.
        if ownerLock >= 0 {
            close(ownerLock)
            ownerLock = -1
        }
    }

    // MARK: - Connections

    private func acceptPending() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 { return }   // EAGAIN: no more for now
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            let admitted = lock.withLock {
                guard connections < Self.maxConnections else { return false }
                connections += 1
                return true
            }
            guard admitted else {
                Self.send(.failure(ControlError(.busy, "too many connections")), to: client)
                close(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        Self.setTimeouts(client)
        let finish: @Sendable (ControlResponse) -> Void = { [self] response in
            Self.send(response, to: client)
            close(client)
            lock.withLock { connections -= 1 }
        }
        let request: ControlRequest
        do {
            request = try ControlRequest.parse(try Self.readRequest(client))
        } catch let error as ControlError {
            finish(.failure(error))
            return
        } catch {
            finish(.failure(ControlError(.internalError, "\(error)")))
            return
        }
        let queued = lock.withLock {
            guard mainBacklog < Self.maxMainBacklog else { return false }
            mainBacklog += 1
            return true
        }
        guard queued else {
            finish(.failure(ControlError(.busy, "too many requests waiting")))
            return
        }
        let handler = self.handler
        DispatchQueue.main.async { [self] in
            lock.withLock { mainBacklog -= 1 }
            MainActor.assumeIsolated {
                handler(request) { response in
                    // Answered off the main thread: a client slow to read
                    // never holds it.
                    DispatchQueue.global(qos: .userInitiated).async { finish(response) }
                }
            }
        }
    }

    /// One request: bytes up to the first newline or end of input.
    static func readRequest(_ fd: Int32) throws -> Data {
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                if let newline = chunk[0..<n].firstIndex(of: 0x0A) {
                    data.append(contentsOf: chunk[0..<newline])
                    break
                }
                data.append(contentsOf: chunk[0..<n])
                if data.count > ControlProtocol.maxRequestBytes {
                    throw ControlError(.invalid, "request larger than \(ControlProtocol.maxRequestBytes) bytes")
                }
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                throw ControlError(.timeout, "no request within \(Int(readTimeout)) s")
            } else {
                throw ControlError(.internalError, "read: \(errno)")
            }
        }
        return data
    }

    private static func send(_ response: ControlResponse, to fd: Int32) {
        let data = response.encoded()
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { break }
            }
        }
    }

    private static func setTimeouts(_ fd: Int32) {
        var noSigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        for (option, seconds) in [(SO_RCVTIMEO, readTimeout), (SO_SNDTIMEO, writeTimeout)] {
            var tv = timeval(tv_sec: Int(seconds), tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}
