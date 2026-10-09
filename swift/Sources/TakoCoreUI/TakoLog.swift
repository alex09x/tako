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
import OSLog

// ── Log levels ───────────────────────────────────────────────────────────────

/// Severity levels for file logging.
public enum TakoLogLevel: Int, Comparable, CaseIterable, Sendable {
    case debug = 0
    case info  = 1
    case error = 2
    case fault = 3

    public static func < (lhs: TakoLogLevel, rhs: TakoLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// ── Session file ─────────────────────────────────────────────────────────────

/// Per-launch log file in ~/Library/Logs/TakoCore/session-<stamp>.log.
///
/// Writes are asynchronous on a serial utility queue so that the terminal's
/// render, input, and parser hot paths are never blocked by file I/O or string
/// formatting. By default, debug-level events are filtered before dispatch to
/// avoid unbounded disk growth and CPU overhead.
public final class TakoSession: @unchecked Sendable {
    public static let shared = TakoSession()

    private let queue = DispatchQueue(label: "tako.log.file", qos: .utility)
    private var handle: FileHandle?
    public private(set) var url: URL?
    private let dir: URL?
    private var currentFileSize: UInt64 = 0
    private let maxFileSizeBytes: UInt64
    private let maxTotalSizeBytes: UInt64
    private let maxFiles: Int
    private let maxAgeSeconds: TimeInterval

    private var _fileLogLevel: TakoLogLevel
    private var lock = os_unfair_lock()

    private lazy var timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    /// Current minimum log level written to the session log file.
    public var fileLogLevel: TakoLogLevel {
        get {
            os_unfair_lock_lock(&lock)
            defer { os_unfair_lock_unlock(&lock) }
            return _fileLogLevel
        }
        set {
            os_unfair_lock_lock(&lock)
            _fileLogLevel = newValue
            os_unfair_lock_unlock(&lock)
        }
    }

    /// Whether verbose debug file logging is enabled. When `false` (default),
    /// high-frequency debug, feed, and render events are discarded before formatting.
    public var isVerboseFileLoggingEnabled: Bool {
        get { fileLogLevel <= .debug }
        set { fileLogLevel = newValue ? .debug : .info }
    }

    private convenience init() {
        let lib = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        let dir = lib?.appendingPathComponent("Logs/TakoCore")
        self.init(
            directory: dir,
            initialLogLevel: Self.defaultFileLogLevel(),
            maxFileSizeBytes: 10 * 1024 * 1024,
            maxTotalSizeBytes: 50 * 1024 * 1024,
            maxFiles: 10,
            maxAgeSeconds: 14 * 86_400
        )
    }

    init(
        directory: URL?,
        initialLogLevel: TakoLogLevel? = nil,
        maxFileSizeBytes: UInt64 = 10 * 1024 * 1024,
        maxTotalSizeBytes: UInt64 = 50 * 1024 * 1024,
        maxFiles: Int = 10,
        maxAgeSeconds: TimeInterval = 14 * 86_400
    ) {
        self.dir = directory
        self._fileLogLevel = initialLogLevel ?? Self.defaultFileLogLevel()
        self.maxFileSizeBytes = maxFileSizeBytes
        self.maxTotalSizeBytes = maxTotalSizeBytes
        self.maxFiles = maxFiles
        self.maxAgeSeconds = maxAgeSeconds

        queue.sync {
            createSessionFileLocked()
            pruneLogsLocked()
        }

        write(cat: "session", level: "I",
              "── launch build=\(Self.buildIdentity()) os=\(ProcessInfo.processInfo.operatingSystemVersionString) ──")
    }

    private static func defaultFileLogLevel() -> TakoLogLevel {
        if let env = ProcessInfo.processInfo.environment["TAKO_LOG_VERBOSE"],
           env == "1" || env.lowercased() == "true" {
            return .debug
        }
        if let envLevel = ProcessInfo.processInfo.environment["TAKO_LOG_LEVEL"]?.lowercased() {
            switch envLevel {
            case "debug": return .debug
            case "info":  return .info
            case "error": return .error
            case "fault": return .fault
            default: break
            }
        }
        if UserDefaults.standard.bool(forKey: "TakoLogVerbose") {
            return .debug
        }
        return .info
    }

    func shouldLog(level: TakoLogLevel) -> Bool {
        fileLogLevel <= level
    }

    func write(cat: String, level: String, _ msg: String) {
        let now = Date()
        queue.async { [weak self] in
            self?.performWrite(cat: cat, level: level, msg: msg, date: now)
        }
    }

    private func performWrite(cat: String, level: String, msg: String, date: Date) {
        guard let fh = handle else { return }
        let ts = timestampFormatter.string(from: date)
        let line = "\(ts) [\(level)] [\(cat)] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }

        fh.write(data)
        currentFileSize += UInt64(data.count)

        if currentFileSize >= maxFileSizeBytes {
            rotateLocked()
        }
    }

    private var fileSequence: UInt64 = 0

    private func createSessionFileLocked() {
        guard let dir = self.dir else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        fileSequence += 1
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime]
        let stamp = fmt.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let pid = ProcessInfo.processInfo.processIdentifier
        let file = dir.appendingPathComponent("session-\(stamp)-\(pid)-\(fileSequence).log")

        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try? FileHandle(forWritingTo: file)
        url = file
        currentFileSize = 0
    }

    private func rotateLocked() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
        createSessionFileLocked()
        pruneLogsLocked()
    }

    private func pruneLogsLocked() {
        guard let dir = self.dir else { return }
        let cutoff = Date().addingTimeInterval(-maxAgeSeconds)

        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var sessionFiles: [(url: URL, date: Date, size: UInt64)] = []
        for item in items where item.lastPathComponent.hasPrefix("session-") && item.pathExtension == "log" {
            let values = try? item.resourceValues(forKeys: [.creationDateKey, .fileSizeKey, .contentModificationDateKey])
            let date = values?.creationDate ?? values?.contentModificationDate ?? Date.distantPast
            let size = UInt64(values?.fileSize ?? 0)

            if date < cutoff && item != self.url {
                try? FileManager.default.removeItem(at: item)
            } else {
                sessionFiles.append((url: item, date: date, size: size))
            }
        }

        sessionFiles.sort {
            if $0.date != $1.date {
                return $0.date < $1.date
            }
            return $0.url.lastPathComponent < $1.url.lastPathComponent
        }

        var totalSize = sessionFiles.reduce(0) { $0 + $1.size }
        while (totalSize > maxTotalSizeBytes || sessionFiles.count > maxFiles), sessionFiles.count > 1 {
            if let index = sessionFiles.firstIndex(where: { $0.url != self.url }) {
                let candidate = sessionFiles.remove(at: index)
                try? FileManager.default.removeItem(at: candidate.url)
                totalSize = totalSize > candidate.size ? totalSize - candidate.size : 0
            } else {
                break
            }
        }
    }

    public func flushForTesting() {
        queue.sync {}
    }

    private static func buildIdentity() -> String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }
}

// ── Dual logger: OSLog + session file ────────────────────────────────────────

/// Writes messages to both the macOS unified log (OSLog) and the session file
/// subject to the configured `fileLogLevel`.
public struct DualLogger: Sendable {
    private let os: Logger
    private let cat: String

    init(subsystem: String, category: String) {
        self.os  = Logger(subsystem: subsystem, category: category)
        self.cat = category
    }

    public func debug(_ message: String) {
        os.debug("\(message, privacy: .public)")
        if TakoLog.fileLogLevel <= .debug {
            TakoSession.shared.write(cat: cat, level: "D", message)
        }
    }

    public func info(_ message: String) {
        os.info("\(message, privacy: .public)")
        if TakoLog.fileLogLevel <= .info {
            TakoSession.shared.write(cat: cat, level: "I", message)
        }
    }

    public func error(_ message: String) {
        os.error("\(message, privacy: .public)")
        if TakoLog.fileLogLevel <= .error {
            TakoSession.shared.write(cat: cat, level: "E", message)
        }
    }

    public func fault(_ message: String) {
        os.fault("\(message, privacy: .public)")
        if TakoLog.fileLogLevel <= .fault {
            TakoSession.shared.write(cat: cat, level: "F", message)
        }
    }
}

public enum TakoLog {
    public static let feed    = DualLogger(subsystem: "tako.core", category: "feed")
    public static let render  = DualLogger(subsystem: "tako.core", category: "render")
    public static let resize  = DualLogger(subsystem: "tako.core", category: "resize")
    public static let metal   = DualLogger(subsystem: "tako.core", category: "metal")
    public static let crash   = DualLogger(subsystem: "tako.core", category: "crash")

    /// The active file logging threshold. Messages below this severity level
    /// are not written to the session log file. Defaults to `.info`.
    public static var fileLogLevel: TakoLogLevel {
        get { TakoSession.shared.fileLogLevel }
        set { TakoSession.shared.fileLogLevel = newValue }
    }

    /// Convenience toggle for verbose file logging. When `false` (the default),
    /// verbose debug lines are skipped.
    public static var isVerboseFileLoggingEnabled: Bool {
        get { TakoSession.shared.isVerboseFileLoggingEnabled }
        set { TakoSession.shared.isVerboseFileLoggingEnabled = newValue }
    }
}
