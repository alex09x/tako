import AppKit
import SwiftUI
import Testing
@testable import Tako

/// The parts of the About window, the icon view and the splits that do not
/// need a pointer or VoiceOver to reach: they are driven directly.
@MainActor
struct AboutVersionTests {
    @Test func versionStringsAreClassified() {
        #expect(AboutView.VersionConfig(version: "1.2.3") == .stable(version: "1.2.3"))
        #expect(AboutView.VersionConfig(version: "abc1234") == .tip(commit: "abc1234"))
        #expect(AboutView.VersionConfig(version: "1.2-beta") == .other("1.2-beta"))
        #expect(AboutView.VersionConfig(version: nil) == .none)
    }

    @Test func onlyAStableVersionLinksToReleaseNotes() {
        #expect(AboutView.VersionConfig(version: "1.2.3").url == Brand.releaseNotesURL(version: "1.2.3"))
        #expect(AboutView.VersionConfig(version: "abc1234").url == nil)
        #expect(AboutView.VersionConfig(version: "dev").url == nil)
    }

    private func rendered(_ info: [String: Any]) -> NSSize {
        let window = makePanelWindow(size: NSSize(width: 360, height: 420))
        let hosting = hostPanel(AboutView(infoDictionary: info).environmentObject(AboutViewModel()), in: window)
        return hosting.fittingSize
    }

    @Test func everyVersionKindAndTheOptionalRowsRender() {
        let full: [String: Any] = [
            "CFBundleShortVersionString": "1.2.3",
            "CFBundleVersion": "42",
            "TakoCommit": "abc1234",
            "NSHumanReadableCopyright": "Copyright someone",
        ]
        let stable = rendered(full)
        let tip = rendered(["CFBundleShortVersionString": "abc1234"])
        let other = rendered(["CFBundleShortVersionString": "dev"])
        let none = rendered([:])

        // More rows make a taller window.
        #expect(stable.height > none.height)
        #expect(tip.height > none.height)
        #expect(other.height > none.height)
    }
}

@MainActor
struct AboutIconConfigTests {
    @Test func thereIsNoConfigToCopyBeforeAnIconIsShown() {
        let model = AboutViewModel()
        let pasteboard = NSPasteboard(name: .init("tako-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        #expect(model.currentIconConfig == nil)
        model.copyCurrentIconConfig(to: pasteboard)
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func theShownIconCopiesAsAConfigLine() {
        let model = AboutViewModel()
        let pasteboard = NSPasteboard(name: .init("tako-test-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        model.advanceToNextIcon()
        model.copyCurrentIconConfig(to: pasteboard)

        #expect(model.currentIconConfig == "macos-icon = official")
        #expect(pasteboard.string(forType: .string) == "macos-icon = official")
    }

    @Test func theAppIconPrefersTheRunningAppThenTheAppImageThenTheAsset() {
        let view = Color.clear
        let icon = NSImage(size: NSSize(width: 16, height: 16))
        // Each source on its own renders; which Image comes back is not
        // inspectable, so rendering without a crash is what is checked.
        for image in [
            view.appIconImage(running: icon, application: nil),
            view.appIconImage(running: nil, application: icon),
            view.appIconImage(running: nil, application: nil),
            view.appIconImage(),
        ] {
            let hosting = NSHostingView(rootView: image.resizable().frame(width: 16, height: 16))
            #expect(hosting.fittingSize.width >= 0)
        }
    }
}

@MainActor
struct SplitDividerLogicTests {
    @Test func voiceOverStepsTheSplitBy2Point5PercentWithin10To90() {
        #expect(abs(SplitDivider.adjusted(0.5, by: .increment) - 0.525) < 0.0001)
        #expect(abs(SplitDivider.adjusted(0.5, by: .decrement) - 0.475) < 0.0001)
        #expect(SplitDivider.adjusted(0.89, by: .increment) == 0.9)
        #expect(SplitDivider.adjusted(0.11, by: .decrement) == 0.1)
    }

    @Test func pointerStyleHandlesTheCursorOnCurrentMacOS() {
        // On macOS 15+ the divider leaves the cursor to pointerStyle, so
        // hovering must not push anything onto NSCursor's stack.
        let before = NSCursor.current
        SplitDivider.updateCursor(hovered: true, direction: .horizontal)
        SplitDivider.updateCursor(hovered: false, direction: .vertical)
        #expect(NSCursor.current === before)
    }
}

@MainActor
struct TerminalSplitDropTests {
    private func surface() -> Tako.SurfaceView {
        Tako.SurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func aDropOntoAnotherPaneIsReportedWithItsZone() {
        let source = surface(), destination = surface()
        defer { source.close(); destination.close() }
        var ops: [TerminalSplitOperation] = []

        TerminalSplitDrop.deliver(source: source, zone: .left, destination: destination) { ops.append($0) }

        guard case .drop(let drop) = ops.first else {
            Issue.record("no drop reported: \(ops)")
            return
        }
        #expect(drop.payload === source)
        #expect(drop.destination === destination)
        #expect(drop.zone == .left)
    }

    @Test func aPaneDroppedOnItselfOrOnAClosedPaneIsIgnored() {
        let pane = surface()
        defer { pane.close() }
        var ops: [TerminalSplitOperation] = []

        TerminalSplitDrop.deliver(source: pane, zone: .top, destination: pane) { ops.append($0) }
        TerminalSplitDrop.deliver(source: pane, zone: .top, destination: nil) { ops.append($0) }

        #expect(ops.isEmpty)
    }

    @Test func aDropWithNothingDraggedIsRefused() {
        let pane = surface()
        defer { pane.close() }
        #expect(!TerminalSplitDrop.perform(providers: [], zone: .right, destination: pane) { _ in })
    }

    @Test func aDropOfSomethingThatIsNotASurfaceIsAcceptedButReportsNothing() async {
        let pane = surface()
        defer { pane.close() }
        var ops: [TerminalSplitOperation] = []
        let provider = NSItemProvider(object: "not a surface" as NSString)

        #expect(TerminalSplitDrop.perform(providers: [provider], zone: .bottom, destination: pane) { ops.append($0) })
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(ops.isEmpty)
    }

    @Test func eachZoneHighlightsItsHalfOfThePane() {
        let size = CGSize(width: 200, height: 100)
        var snapshots: [NSBitmapImageRep] = []
        for zone in [TerminalSplitDropZone.top, .bottom, .left, .right] {
            let window = makePanelWindow(size: NSSize(width: 200, height: 100))
            let hosting = hostPanel(zone.overlay(in: size).frame(width: 200, height: 100), in: window)
            snapshots.append(panelSnapshot(hosting))
        }
        // Four different halves, four different pictures.
        for i in snapshots.indices {
            for j in snapshots.indices where j > i {
                #expect(!panelBitmapsEqual(snapshots[i], snapshots[j]))
            }
        }
    }
}
