import AppKit
import Darwin

/// Tako's own record of its windows, tabs and splits, so a crash -- which
/// AppKit's restoration does not survive -- does not lose them.
///
/// Two files in `Application Support/<bundle id>/layout/`:
/// - `launch.json`: how the last run ended (`LaunchState`);
/// - `journal-<generation>.json`: the layout, a new generation shortly after
///   any change; `launch.json` names the current one.
///
/// At launch, `decide` picks one source of windows: AppKit's restoration
/// after a clean quit, this journal after a run that did not end cleanly,
/// nothing on a first run. Never both.
enum LayoutJournal {
    static let version = 1

    // Limits checked on the raw JSON before any window or pane exists.
    static let maxFileBytes = 4 << 20
    static let maxWindows = 64
    static let maxTabs = 256
    static let maxPanes = 1024
    static let maxDepth = 64
    static let maxString = 4096

    // MARK: - How the last run ended

    enum LaunchState: String, Codable {
        /// No launch.json: Tako has not run with this bundle id before.
        case firstRun
        /// Running, or ended without quitting: a crash, a kill, a power cut.
        case dirty
        /// Rebuilding windows from the journal; a crash here restores again.
        case restoring
        /// Quit normally, after the final journal write.
        case clean
    }

    struct LaunchRecord: Codable, Equatable {
        var state: LaunchState
        var journalGeneration: UInt64
    }

    enum Source: Equatable {
        /// AppKit restores what it saved at the last quit (or nothing).
        case appKit
        /// The journal: the last run did not end cleanly and it is intact.
        case journal
    }

    enum JournalRead: Equatable {
        case valid
        case invalid(String)
        case missing
    }

    /// The journal file of one generation. Each generation is a file of its
    /// own, written whole before `launch.json` names it, and older ones are
    /// removed only after: a crash at any point leaves `launch.json` naming
    /// a generation whose file is complete -- the old one or the new one.
    static func journalName(_ generation: UInt64) -> String { "journal-\(generation).json" }

    /// What a journal file read as, given the generation `launch.json` names:
    /// valid only when it parses, passes every limit and is that generation.
    static func check(_ data: Data?, expected generation: UInt64) -> (JournalRead, Journal?) {
        guard let data else { return (.missing, nil) }
        switch read(data) {
        case .failure(let e): return (.invalid(e.description), nil)
        case .success(let j):
            guard j.generation == generation else {
                return (.invalid("journal generation \(j.generation), launch record names \(generation)"), nil)
            }
            return (.valid, j)
        }
    }

    /// The one place the launch decision is made.
    static func decide(previous: LaunchState, journal: JournalRead) -> Source {
        switch (previous, journal) {
        case (.dirty, .valid), (.restoring, .valid):
            return .journal
        default:
            // A clean quit, a first run, or a journal that cannot be trusted:
            // AppKit's own restoration (which after a crash may be nothing).
            return .appKit
        }
    }

    // MARK: - Files

    static func directory(bundleID: String) throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw JournalError("no Application Support")
        }
        let dir = base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("layout", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var st = stat()
        guard lstat(dir.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_uid == getuid() else {
            throw JournalError("\(dir.path) is not this user's directory")
        }
        if st.st_mode & 0o077 != 0 { chmod(dir.path, 0o700) }
        return dir
    }

    struct JournalError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    /// Replaces `url` with `data` so that a crash at any point leaves either
    /// the old file or the new one, whole: a temporary file in the same
    /// directory, synced, renamed over, and the directory synced.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent().path
        let tmp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(getpid()).\(UInt32.random(in: 0...UInt32.max)).tmp").path
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw JournalError("open \(tmp): \(errno)") }
        var ok = false
        defer { if !ok { unlink(tmp) } }
        let written = data.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n > 0 { offset += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
        guard written, fsync(fd) == 0 else { close(fd); throw JournalError("write \(tmp): \(errno)") }
        close(fd)
        guard rename(tmp, url.path) == 0 else { throw JournalError("rename: \(errno)") }
        ok = true
        let dfd = open(dir, O_RDONLY | O_CLOEXEC)
        if dfd >= 0 { fsync(dfd); close(dfd) }
    }

    static func readLaunch(in dir: URL) -> LaunchRecord {
        let url = dir.appendingPathComponent("launch.json")
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(LaunchRecord.self, from: data) else {
            return LaunchRecord(state: FileManager.default.fileExists(atPath: url.path) ? .dirty : .firstRun,
                                journalGeneration: 0)
        }
        return record
    }

    static func writeLaunch(_ record: LaunchRecord, in dir: URL) throws {
        try atomicWrite(try JSONEncoder().encode(record), to: dir.appendingPathComponent("launch.json"))
    }

    // MARK: - The journal

    /// What a window looks like in the journal. Tabs are kept as raw JSON
    /// (each a `TerminalRestorableState`) so the whole file is checked
    /// before decoding one -- decoding a tab creates its panes.
    struct Window {
        var frame: CGRect
        var isKey: Bool
        var selectedTab: Int
        var tabs: [Any]
    }

    struct Journal {
        var generation: UInt64
        var windows: [Window]
    }

    static func encode(_ journal: Journal) throws -> Data {
        let object: [String: Any] = [
            "version": version,
            "generation": journal.generation,
            "windows": journal.windows.map { w -> [String: Any] in
                ["frame": [w.frame.origin.x, w.frame.origin.y, w.frame.size.width, w.frame.size.height],
                 "key": w.isKey, "selectedTab": w.selectedTab, "tabs": w.tabs]
            },
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    /// Reads and checks the journal without creating anything. Any problem
    /// -- size, syntax, version, shape, limits -- rejects the whole file.
    static func read(_ data: Data) -> Result<Journal, JournalError> {
        guard data.count <= maxFileBytes else { return .failure(JournalError("journal larger than \(maxFileBytes) bytes")) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(JournalError("journal is not a JSON object"))
        }
        guard root["version"] as? Int == version else { return .failure(JournalError("unsupported journal version")) }
        guard let generation = (root["generation"] as? NSNumber)?.uint64Value else {
            return .failure(JournalError("journal has no generation"))
        }
        guard let rawWindows = root["windows"] as? [[String: Any]] else {
            return .failure(JournalError("journal has no windows"))
        }
        guard rawWindows.count <= maxWindows else { return .failure(JournalError("too many windows")) }
        var windows: [Window] = []
        var tabCount = 0, paneCount = 0
        for raw in rawWindows {
            guard let f = raw["frame"] as? [Double], f.count == 4, f.allSatisfy(\.isFinite), f[2] > 0, f[3] > 0,
                  let tabs = raw["tabs"] as? [[String: Any]], !tabs.isEmpty,
                  let selected = raw["selectedTab"] as? Int, tabs.indices.contains(selected),
                  let isKey = raw["key"] as? Bool else {
                return .failure(JournalError("a window entry is malformed"))
            }
            tabCount += tabs.count
            guard tabCount <= maxTabs else { return .failure(JournalError("too many tabs")) }
            for tab in tabs {
                switch shape(tab, depth: 0) {
                case .failure(let e): return .failure(e)
                case .success(let leaves): paneCount += leaves
                }
                guard paneCount <= maxPanes else { return .failure(JournalError("too many panes")) }
            }
            windows.append(Window(frame: CGRect(x: f[0], y: f[1], width: f[2], height: f[3]),
                                  isKey: isKey, selectedTab: selected, tabs: tabs))
        }
        return .success(Journal(generation: generation, windows: windows))
    }

    /// Depth, string sizes and the number of panes (`view` keys) of a value.
    private static func shape(_ value: Any, depth: Int) -> Result<Int, JournalError> {
        guard depth <= maxDepth else { return .failure(JournalError("journal nested too deeply")) }
        switch value {
        case let s as String:
            return s.utf8.count <= maxString ? .success(0) : .failure(JournalError("a string is too long"))
        case let a as [Any]:
            var n = 0
            for v in a {
                switch shape(v, depth: depth + 1) {
                case .failure(let e): return .failure(e)
                case .success(let c): n += c
                }
            }
            return .success(n)
        case let o as [String: Any]:
            var n = o["view"] != nil ? 1 : 0
            for (k, v) in o {
                guard k.utf8.count <= maxString else { return .failure(JournalError("a key is too long")) }
                switch shape(v, depth: depth + 1) {
                case .failure(let e): return .failure(e)
                case .success(let c): n += c
                }
            }
            return .success(n)
        default:
            return .success(0)
        }
    }
}
