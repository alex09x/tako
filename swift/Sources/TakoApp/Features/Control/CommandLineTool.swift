import AppKit

/// `takoctl` ships inside the app (Contents/MacOS) but is not on anyone's
/// PATH from there. This puts a link to it where shells look -- asked once
/// at launch, and on demand from the Tako menu.
@MainActor
enum CommandLineTool {
    static let name = "takoctl"
    /// Remembers "Don't Ask Again" from the launch question.
    static let declinedKey = "TakoctlInstallDeclined"

    /// Candidate directories where shells look:
    /// Homebrew on Apple silicon (/opt/homebrew/bin),
    /// system / Intel Homebrew (/usr/local/bin),
    /// modern user bin (~/.local/bin), and user bin (~/bin).
    nonisolated static var directories: [String] {
        var dirs = ["/opt/homebrew/bin", "/usr/local/bin"]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let localBin = (home as NSString).appendingPathComponent(".local/bin")
        let userBin = (home as NSString).appendingPathComponent("bin")
        if !dirs.contains(localBin) { dirs.append(localBin) }
        if !dirs.contains(userBin) { dirs.append(userBin) }
        return dirs
    }

    /// The copy inside this app, if the bundle carries one.
    static var bundled: String? {
        guard let dir = Bundle.main.executableURL?.deletingLastPathComponent() else { return nil }
        let path = dir.appendingPathComponent(name).path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// True when some directory on the list already has a `takoctl` that
    /// runs this app's copy.
    static func isInstalled(bundled: String, directories: [String] = directories) -> Bool {
        directories.contains { dir in
            let link = (dir as NSString).appendingPathComponent(name)
            return (try? FileManager.default.destinationOfSymbolicLink(atPath: link))
                .map { ($0 as NSString).standardizingPath == (bundled as NSString).standardizingPath } ?? false
        }
    }

    /// What a Tako bundle's copy looks like at the end of a link.
    static let bundleSuffix = ".app/Contents/MacOS/\(name)"

    /// Bundle identifiers that are Tako: the release and its local builds
    /// (`com.tako-core.terminal.demo` and the like).
    static let bundleIdentifierPrefix = "com.tako-core.terminal"

    /// What is at `link`, read without following it: nothing (nil target,
    /// replaceable), a link to a Tako's own copy (its target, replaceable),
    /// or anything else -- another tool's, or a link whose app is gone or
    /// cannot be told to be Tako -- which is never touched.
    enum Occupant: Equatable { case empty, tako(target: String), other }

    static func occupant(_ link: String) -> Occupant {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: link) else { return .empty }
        guard attrs[.type] as? FileAttributeType == .typeSymbolicLink,
              let target = try? fm.destinationOfSymbolicLink(atPath: link),
              target.hasSuffix(bundleSuffix) else { return .other }
        // The app the link runs, and what it says it is.
        let resolved = URL(fileURLWithPath: target, relativeTo: URL(fileURLWithPath: (link as NSString).deletingLastPathComponent))
        let app = resolved.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let id = Bundle(url: app)?.bundleIdentifier,
              id == bundleIdentifierPrefix || id.hasPrefix(bundleIdentifierPrefix + ".") else { return .other }
        return .tako(target: target)
    }

    static func replaceable(_ link: String) -> Bool { occupant(link) != .other }

    /// The directory to link into without a password: one that exists, is
    /// writable, and has no `takoctl` but a Tako's.
    static func writableDirectory(directories: [String] = directories) -> String? {
        let fm = FileManager.default
        return directories.first { dir in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                  fm.isWritableFile(atPath: dir) else { return false }
            return replaceable((dir as NSString).appendingPathComponent(name))
        }
    }

    /// Why it was not installed, when nowhere would take it.
    static func occupied(directories: [String] = directories) -> String? {
        directories.map { ($0 as NSString).appendingPathComponent(name) }.first { !replaceable($0) }
    }

    /// Links `takoctl` in using direct system calls; answers where, or nil when it could not.
    /// Never invokes osascript or elevates privileges.
    static func install(bundled: String, directories: [String] = directories) -> String? {
        if let dir = writableDirectory(directories: directories) {
            return linkInDirectory(dir, bundled: bundled)
        }

        // If no candidate directory is currently available, try creating ~/.local/bin
        // if it is in the candidate directories list (native user-space system call).
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let localBin = (home as NSString).appendingPathComponent(".local/bin")
        if directories.contains(localBin) {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: localBin, isDirectory: &isDir) {
                try? fm.createDirectory(atPath: localBin, withIntermediateDirectories: true)
            }
            if let dir = writableDirectory(directories: [localBin]) {
                return linkInDirectory(dir, bundled: bundled)
            }
        }

        return nil
    }

    private static func linkInDirectory(_ dir: String, bundled: String) -> String? {
        let link = (dir as NSString).appendingPathComponent(name)
        let fresh = (dir as NSString).appendingPathComponent(".\(name).\(UUID().uuidString)")
        if (try? FileManager.default.createSymbolicLink(atPath: fresh, withDestinationPath: bundled)) != nil {
            if rename(fresh, link) == 0 { return link }
            try? FileManager.default.removeItem(atPath: fresh)
        }
        return nil
    }

    /// At launch: asks once, in a terminal window, when it is not installed.
    static func offerAtLaunch(theme: TerminalTheme?) {
        guard NSClassFromString("XCTestCase") == nil,
              let bundled, !isInstalled(bundled: bundled),
              !UserDefaults.tako.bool(forKey: declinedKey) else { return }
        // After the windows are up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows),
                  TerminalDialogView.pending(in: window) == nil else { return }
            Task { @MainActor in
                let answer = await TerminalDialogView.choose(
                    in: window, title: "Install the takoctl command?",
                    lines: TUIText.plain("takoctl drives Tako from a shell or a script: windows, tabs, splits, running programs and reading what they print. Installing links it where your shell finds it.", width: 56),
                    choices: [.init(title: "Not Now", kind: .normal),
                              .init(title: "Don't Ask Again", kind: .normal),
                              .init(title: "Install", kind: .primary)],
                    selected: 2, cancelIndex: 0, theme: theme)
                switch answer {
                case 2: run(in: window, bundled: bundled, theme: theme)
                case 1: UserDefaults.tako.set(true, forKey: declinedKey)
                default: break
                }
            }
        }
    }

    /// From the menu: installs, and says how it went.
    static func installFromMenu(theme: TerminalTheme?) {
        let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows)
        guard let bundled else {
            report(in: window, title: "takoctl", text: "This copy of Tako carries no takoctl.", theme: theme)
            return
        }
        run(in: window, bundled: bundled, theme: theme)
    }

    private static func run(in window: NSWindow?, bundled: String, theme: TerminalTheme?) {
        if let link = install(bundled: bundled) {
            report(in: window, title: "takoctl installed",
                   text: "\(link) → the copy inside Tako. Try: takoctl tree", theme: theme)
        } else {
            let reason = occupied().map { "\($0) is another program's; it was left alone." } ?? "Could not link it."
            report(in: window, title: "takoctl not installed",
                   text: "\(reason) By hand: ln -s \(bundled) <a directory on your PATH>/\(name)", theme: theme)
        }
    }

    private static func report(in window: NSWindow?, title: String, text: String, theme: TerminalTheme?) {
        guard let window else {
            let alert = NSAlert()
            alert.messageText = title
            alert.informativeText = text
            alert.runModal()
            return
        }
        Task { @MainActor in
            _ = await TerminalDialogView.choose(
                in: window, title: title, lines: TUIText.plain(text, width: 56),
                choices: [.init(title: "OK", kind: .primary)], selected: 0, cancelIndex: 0, theme: theme)
        }
    }
}
