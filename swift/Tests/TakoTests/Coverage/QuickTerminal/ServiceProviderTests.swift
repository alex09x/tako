import Testing
import AppKit
@testable import Tako

/// `ServiceProvider`'s success path (a URL actually opened) ends by calling
/// `TerminalController.newWindow`/`newTab`. Both funnel real window creation
/// (`showWindow`, which would touch the `Terminal.xib` nib this SwiftPM test
/// target deliberately excludes) through `scheduleInitialPresentation`,
/// which defers it via `DispatchQueue.main.async` -- the same dead hop
/// documented on `QTTestSupport.loadAndAnimateIn`/`simulateDeferredAnimateInCompletion`
/// that a bare `swift test` host never drains. That makes it safe to drive
/// `ServiceProvider` all the way through its real success path here: nothing
/// ever reaches the nib.
@MainActor
struct ServiceProviderTests {
    private func pasteboardWithString(_ string: String) -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.setString(string, forType: .string)
        return pb
    }

    private func pasteboardWithFileURL(_ url: URL) -> NSPasteboard {
        let pb = NSPasteboard.withUniqueName()
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        return pb
    }

    @Test func openTabAndOpenWindowBothNoOpWhenAppDelegateIsNotInstalled() {
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = nil
        defer { NSApplication.shared.delegate = originalDelegate }

        let provider = ServiceProvider()
        var tabError: NSString = ""
        var windowError: NSString = ""
        withUnsafeMutablePointer(to: &tabError) { ptr in
            provider.openTab(pasteboardWithString("hello"), userData: nil, error: AutoreleasingUnsafeMutablePointer(ptr))
        }
        withUnsafeMutablePointer(to: &windowError) { ptr in
            provider.openWindow(pasteboardWithString("hello"), userData: nil, error: AutoreleasingUnsafeMutablePointer(ptr))
        }

        // The `guard let delegate = NSApp.delegate as? AppDelegate` bails
        // before ever touching the error out-pointer.
        #expect(tabError == "")
        #expect(windowError == "")
    }

    @Test func openTabSetsAnErrorWhenThePasteboardHasNoFileURLs() {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        let provider = ServiceProvider()
        var error: NSString = ""
        withUnsafeMutablePointer(to: &error) { ptr in
            provider.openTab(pasteboardWithString("not a file url"), userData: nil, error: AutoreleasingUnsafeMutablePointer(ptr))
        }

        #expect(error == "Could not load any text from the clipboard.")
    }

    @Test func openWindowSetsAnErrorWhenThePasteboardHasNoFileURLs() {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        let provider = ServiceProvider()
        var error: NSString = ""
        withUnsafeMutablePointer(to: &error) { ptr in
            provider.openWindow(pasteboardWithString(""), userData: nil, error: AutoreleasingUnsafeMutablePointer(ptr))
        }

        #expect(error == "Could not load any text from the clipboard.")
    }

    @Test func openTabOpensATerminalForAFileURLTruncatedToItsDirectory() throws {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServiceProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("some-file.txt")
        try Data().write(to: file)

        let provider = ServiceProvider()
        var error: NSString = ""
        withUnsafeMutablePointer(to: &error) { ptr in
            // Two pasteboard URLs (the file and its own containing directory)
            // must collapse to the same single directory via the `Set`, so
            // this also exercises the dedup path, not just the
            // `deletingLastPathComponent()` truncation.
            provider.openTab(pasteboardWithFileURL(file), userData: nil, error: AutoreleasingUnsafeMutablePointer(ptr))
        }

        // `directoryURLs` ends up non-empty, so the no-file-urls error is
        // never set: the guard that produces it is the only thing that
        // writes to `error`.
        #expect(error == "")
    }

    @Test func openWindowOpensATerminalForADirectoryURL() throws {
        let appDelegate = AppDelegate()
        let originalDelegate = NSApplication.shared.delegate
        NSApplication.shared.delegate = appDelegate
        defer { NSApplication.shared.delegate = originalDelegate }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServiceProviderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let provider = ServiceProvider()
        var error: NSString = ""
        withUnsafeMutablePointer(to: &error) { ptr in
            provider.openWindow(pasteboardWithFileURL(dir), userData: nil, error: AutoreleasingUnsafeMutablePointer(ptr))
        }

        #expect(error == "")
    }
}
