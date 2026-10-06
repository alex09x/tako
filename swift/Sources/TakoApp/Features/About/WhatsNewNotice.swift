import AppKit
import Foundation

/// Presents a terminal-style announcement card at launch for new releases,
/// summarizing the version, highlights, and fixes, matching the TakoCore palette (`TakoTUI`).
/// Can also be viewed anytime from the menu or the About window.
@MainActor
enum WhatsNewNotice {
    /// Remembers the last version for which the What's New announcement was shown.
    static let lastAnnouncedKey = "TakoLastAnnouncedVersion"

    /// The current application version string (e.g. "0.1.6").
    nonisolated static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.1.7"
    }

    /// Release highlights for Tako versions.
    static func releaseNotes(for version: String) -> String {
        """
        ## What's New in Tako v\(version)

        - **Interactive Scrollbar**: Always-on track and draggable thumb with full scrollback navigation and alternate-screen DEC 1007 support.
        - **Zero-Privilege CLI**: Clean symlink installation for `tako` and `takoctl` directly into `~/.local/bin` without AppleScript or sudo password dialogs.
        - **In-App Updater Relaunch**: Instant one-click relaunch after background updates are installed.
        - **Top-Bar About & Quick Controls**: Dedicated About/Info button and terminal controls in the window header across all window modes.
        - **Session Durability**: Seamless process recovery and scrollback restoration across app relaunches.
        """
    }

    /// Formatted TUI lines for the What's New dialog.
    static func lines(for version: String = currentVersion, width: Int = 62) -> [TUIText.Line] {
        var result: [TUIText.Line] = [
            TUIText.Line(runs: [
                TUIText.Run(text: "Fast, native, GPU-accelerated terminal for macOS", kind: .muted)
            ]),
            TUIText.Line(runs: [])
        ]
        result += TUIText.markdown(releaseNotes(for: version), width: width, maxLines: 50)
        return result
    }

    /// Offers the What's New announcement at launch if this version hasn't been announced yet.
    static func offerAtLaunch(theme: TerminalTheme?) {
        guard NSClassFromString("XCTestCase") == nil,
              Tako.launchSource == .app || Tako.launchSource == .cli else { return }

        let version = currentVersion
        let lastAnnounced = UserDefaults.tako.string(forKey: lastAnnouncedKey)
        guard lastAnnounced != version else { return }

        // Give the window 0.8s to finish mounting and layout
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows),
                  TerminalDialogView.pending(in: window) == nil else { return }
            show(in: window, version: version, theme: theme)
        }
    }

    /// Shows the What's New dialog immediately in the active window.
    static func showWhatsNew(force: Bool = true, theme: TerminalTheme? = nil) {
        guard let window = AppUpdater.noticeWindow(key: NSApp.keyWindow, windows: NSApp.windows) else {
            AboutController.shared.show()
            return
        }
        let activeTheme = theme ?? (NSApp.delegate as? AppDelegate)?.tako.config.theme
        if let existing = TerminalDialogView.pending(in: window) {
            existing.withdraw()
        }
        show(in: window, version: currentVersion, theme: activeTheme)
    }

    private static func show(in window: NSWindow, version: String, theme: TerminalTheme?) {
        let noteLines = lines(for: version, width: 62)
        Task { @MainActor in
            let answer = await TerminalDialogView.choose(
                in: window,
                title: "Tako v\(version)",
                lines: noteLines,
                choices: [
                    .init(title: "View on GitHub", kind: .normal),
                    .init(title: "Got It", kind: .primary)
                ],
                selected: 1,
                cancelIndex: 1,
                theme: theme
            )

            // Mark this version as seen
            UserDefaults.tako.set(version, forKey: lastAnnouncedKey)

            if answer == 0 {
                if let url = Brand.releaseNotesURL(version: version) {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
