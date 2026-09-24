import Foundation
import OSLog

// ── Session file ─────────────────────────────────────────────────────────────

/// Per-launch log file in ~/Library/Logs/TakoCore/session-<stamp>.log.
///
/// Initialized on first use (lazy singleton). Writes are async on a serial
/// utility queue so the feed path is never blocked.
public final class TakoSession: @unchecked Sendable {
    public static let shared = TakoSession()

    private let queue = DispatchQueue(label: "tako.log.file", qos: .utility)
    private var handle: FileHandle?
    public private(set) var url: URL?

    private init() {
        guard let lib = FileManager.default.urls(
            for: .libraryDirectory, in: .userDomainMask
        ).first else { return }

        let dir = lib.appendingPathComponent("Logs/TakoCore")
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)

        // Prune sessions older than 14 days so the folder doesn't grow forever.
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        if let items = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.creationDateKey]
        ) {
            for item in items {
                if let created = try? item.resourceValues(
                    forKeys: [.creationDateKey]).creationDate,
                   created < cutoff {
                    try? FileManager.default.removeItem(at: item)
                }
            }
        }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = fmt.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = dir.appendingPathComponent("session-\(stamp).log")

        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try? FileHandle(forWritingTo: file)
        url = file

        write(cat: "session", level: "I",
              "── launch build=\(Self.buildIdentity()) os=\(ProcessInfo.processInfo.operatingSystemVersionString) ──")
    }

    func write(cat: String, level: String, _ msg: String) {
        guard let fh = handle else { return }
        let ts = Self.timestamp()
        let line = "\(ts) [\(level)] [\(cat)] \(msg)\n"
        queue.async { fh.write(Data(line.utf8)) }
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// The build this log came from.
    ///
    /// Once this ran `/usr/bin/git log -1` and waited for it, which is two
    /// things a shipped library must never do: it spawns a child process
    /// inside somebody else's application, and it blocks the thread that
    /// asked for the first log line -- usually the main one, during view
    /// setup. A consumer asserting that constructing a terminal starts no
    /// descendant process would fail on a logging convenience.
    ///
    /// The commit belongs to the application that embeds this package, not to
    /// the package, so it is no longer reported here.
    private static func buildIdentity() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}

// ── Dual logger: OSLog + session file ────────────────────────────────────────

/// Writes every message to both the macOS unified log and the session file.
///
/// Usage:
///   TakoLog.feed.debug("batch \(n)B")
///   TakoLog.resize.info("80×24 → 160×48")
///   TakoLog.metal.error("makeCommandBuffer returned nil")
public struct DualLogger: Sendable {
    private let os: Logger
    private let cat: String

    init(subsystem: String, category: String) {
        self.os  = Logger(subsystem: subsystem, category: category)
        self.cat = category
    }

    public func debug(_ message: String) {
        os.debug("\(message, privacy: .public)")
        TakoSession.shared.write(cat: cat, level: "D", message)
    }

    public func info(_ message: String) {
        os.info("\(message, privacy: .public)")
        TakoSession.shared.write(cat: cat, level: "I", message)
    }

    public func error(_ message: String) {
        os.error("\(message, privacy: .public)")
        TakoSession.shared.write(cat: cat, level: "E", message)
    }

    public func fault(_ message: String) {
        os.fault("\(message, privacy: .public)")
        TakoSession.shared.write(cat: cat, level: "F", message)
    }
}

public enum TakoLog {
    public static let feed    = DualLogger(subsystem: "tako.core", category: "feed")
    public static let render  = DualLogger(subsystem: "tako.core", category: "render")
    public static let resize  = DualLogger(subsystem: "tako.core", category: "resize")
    public static let metal   = DualLogger(subsystem: "tako.core", category: "metal")
    public static let crash   = DualLogger(subsystem: "tako.core", category: "crash")
}
