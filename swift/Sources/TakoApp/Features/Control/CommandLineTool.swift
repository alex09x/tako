import AppKit

/// `takoctl` ships inside the app (Contents/MacOS) but is not on anyone's
/// PATH from there. This puts a link to it where shells look -- asked once
/// at launch, and on demand from the Tako menu.
@MainActor
enum CommandLineTool {
    static let name = "takoctl"
    /// Remembers "Don't Ask Again" from the launch question.
    static let declinedKey = "TakoctlInstallDeclined"

    /// Where shells find it: Homebrew's directory on Apple silicon first (it
    /// is the user's own, no password), then the system-wide one.
    static let directories = ["/opt/homebrew/bin", "/usr/local/bin"]

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

    /// The directory to link into without a password: one that exists, is
    /// writable, and holds no `takoctl` other than a link (an older Tako's).
    static func writableDirectory(directories: [String] = directories) -> String? {
        let fm = FileManager.default
        return directories.first { dir in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue,
                  fm.isWritableFile(atPath: dir) else { return false }
            let link = (dir as NSString).appendingPathComponent(name)
            let attrs = try? fm.attributesOfItem(atPath: link)
            return attrs == nil || attrs?[.type] as? FileAttributeType == .typeSymbolicLink
        }
    }

    /// Links `takoctl` in; answers where, or nil when it could not.
    static func install(bundled: String) -> String? {
        if let dir = writableDirectory() {
            let link = (dir as NSString).appendingPathComponent(name)
            try? FileManager.default.removeItem(atPath: link)
            if (try? FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: bundled)) != nil {
                return link
            }
        }
        // Nowhere writable: the system directory, with the administrator's
        // password, asked by macOS itself.
        let link = "/usr/local/bin/\(name)"
        let shell = "/bin/mkdir -p /usr/local/bin && /bin/ln -sf \(quoted(bundled)) \(quoted(link))"
        let script = "do shell script \"\(shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        return process.terminationStatus == 0 ? link : nil
    }

    private static func quoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
            report(in: window, title: "takoctl not installed",
                   text: "Could not link it. By hand: ln -s \(bundled) /usr/local/bin/\(name)", theme: theme)
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
