import Testing
import Foundation
import AppKit
import SwiftUI
@testable import Tako

@MainActor
private func withOffscreenViewWindow<T>(_ body: (NSWindow) -> T) -> T {
    let frame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
    let window = NSWindow(
        contentRect: NSRect(x: frame.minX + 10, y: frame.minY + 10, width: 300, height: 200),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    defer { window.close() }
    return body(window)
}

@MainActor
struct NSViewExtensionTests {
    private final class NamedView: NSView {}
    private final class OtherNamedView: NSView {}
    private final class FocusableView: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    @Test func isFirstResponderAndResponderChainReflectRealFocus() {
        withOffscreenViewWindow { window in
            // A plain focusable view: an NSTextField hands first responder to
            // its field editor, so the field itself never reports it.
            let field = FocusableView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
            window.contentView?.addSubview(field)
            window.orderFrontRegardless()
            window.makeFirstResponder(field)

            #expect(field.isFirstResponder)
            #expect(field.isInResponderChain)

            let other = NSView(frame: .zero)
            window.contentView?.addSubview(other)
            #expect(!other.isFirstResponder)
        }
    }

    @Test func screenshotProducesNSImageMatchingBounds() {
        withOffscreenViewWindow { window in
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 50, height: 40))
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.red.cgColor
            window.contentView?.addSubview(view)
            window.orderFrontRegardless()
            view.displayIfNeeded()

            let image: NSImage? = view.screenshot()
            #expect(image != nil)
            #expect(image?.size.width == 50)
            #expect(image?.size.height == 40)
        }
    }

    @Test func screenshotAsSwiftUIImageIsProduced() {
        withOffscreenViewWindow { window in
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 30, height: 20))
            window.contentView?.addSubview(view)
            window.orderFrontRegardless()

            let image: Image? = view.screenshot()
            #expect(image != nil)
        }
    }

    @Test func rootViewWalksToTopOfHierarchy() {
        let root = NSView(frame: .zero)
        let middle = NSView(frame: .zero)
        let leaf = NSView(frame: .zero)
        root.addSubview(middle)
        middle.addSubview(leaf)

        #expect(leaf.rootView === root)
        #expect(root.rootView === root)
    }

    @Test func containsDetectsDescendantView() {
        let root = NSView(frame: .zero)
        let middle = NSView(frame: .zero)
        let leaf = NSView(frame: .zero)
        root.addSubview(middle)
        middle.addSubview(leaf)

        #expect(root.contains(leaf))
        #expect(root.contains(root))
        #expect(!leaf.contains(root))
    }

    @Test func containsClassNameFindsMatchingSubviewsAtAnyDepth() {
        let root = NSView(frame: .zero)
        let middle = NSView(frame: .zero)
        let named = NamedView(frame: .zero)
        root.addSubview(middle)
        middle.addSubview(named)

        #expect(root.contains(className: "NamedView"))
        #expect(!root.contains(className: "SomethingElse"))
        #expect(named.contains(className: "NamedView"))
    }

    @Test func firstSuperviewWithClassNameFindsAncestor() {
        let root = NamedView(frame: .zero)
        let middle = NSView(frame: .zero)
        let leaf = NSView(frame: .zero)
        root.addSubview(middle)
        middle.addSubview(leaf)

        #expect(leaf.firstSuperview(withClassName: "NamedView") === root)
        #expect(root.firstSuperview(withClassName: "NamedView") == nil)
    }

    @Test func firstDescendantWithClassNameFindsDeepestFirstMatch() {
        let root = NSView(frame: .zero)
        let middle = NSView(frame: .zero)
        let named = NamedView(frame: .zero)
        root.addSubview(middle)
        middle.addSubview(named)

        #expect(root.firstDescendant(withClassName: "NamedView") === named)
        #expect(root.firstDescendant(withClassName: "NoSuchClass") == nil)
    }

    @Test func descendantsWithClassNameFindsAllMatches() {
        let root = NSView(frame: .zero)
        let a = NamedView(frame: .zero)
        let b = NamedView(frame: .zero)
        let other = OtherNamedView(frame: .zero)
        root.addSubview(a)
        root.addSubview(other)
        other.addSubview(b)

        let matches = root.descendants(withClassName: "NamedView")
        #expect(matches.count == 2)
        #expect(matches.contains(where: { $0 === a }))
        #expect(matches.contains(where: { $0 === b }))
    }

    @Test func firstDescendantWithIDFindsMatchingIdentifier() {
        let root = NSView(frame: .zero)
        let middle = NSView(frame: .zero)
        let target = NSView(frame: .zero)
        target.identifier = NSUserInterfaceItemIdentifier("target-view")
        root.addSubview(middle)
        middle.addSubview(target)

        #expect(root.firstDescendant(withID: "target-view") === target)
        #expect(root.firstDescendant(withID: "missing-id") == nil)
    }

    @Test func firstViewFromRootSearchesEntireHierarchyIncludingRootItself() {
        withOffscreenViewWindow { window in
            guard let contentView = window.contentView else {
                Issue.record("Expected a content view")
                return
            }
            let named = NamedView(frame: .zero)
            contentView.addSubview(named)

            let found = named.firstViewFromRoot(withClassName: "NamedView")
            #expect(found === named)

            let rootItself = contentView.rootView
            let foundRoot = named.firstViewFromRoot(withClassName: String(describing: type(of: rootItself)))
            #expect(foundRoot === rootItself)
        }
    }

    @Test func viewHierarchyDescriptionIncludesClassNameFrameAndIdentifier() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        let child = NamedView(frame: NSRect(x: 1, y: 1, width: 5, height: 5))
        child.identifier = NSUserInterfaceItemIdentifier("child-id")
        child.isHidden = true
        root.addSubview(child)

        let description = root.viewHierarchyDescription()
        #expect(description.contains("NSView"))
        #expect(description.contains("NamedView"))
        #expect(description.contains("child-id"))
        #expect(description.contains("hidden"))
        #expect(description.contains("transparent") || description.contains("opaque"))
    }

    @Test func viewHierarchyDescriptionIncludesLayerBackgroundColorWhenLayerBacked() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.red.cgColor

        let description = root.viewHierarchyDescription()
        #expect(description.contains("layer-backed"))
        #expect(description.contains("bg:rgba"))
    }

    @Test func printViewHierarchyWritesTheDescriptionToStandardOutput() {
        withOffscreenViewWindow { window in
            let named = NamedView(frame: .zero)
            window.contentView?.addSubview(named)

            let captured = captureStandardOutput {
                named.printViewHierarchy()
            }

            #expect(captured.contains("View Hierarchy from Root:"))
            #expect(captured.contains("NamedView"))
        }
    }
}

/// Redirects fd 1 to a pipe for the duration of `body` and returns everything written to it.
private func captureStandardOutput(_ body: () -> Void) -> String {
    fflush(stdout)
    let originalStdout = dup(1)
    let pipe = Pipe()
    dup2(pipe.fileHandleForWriting.fileDescriptor, 1)

    body()

    fflush(stdout)
    // Put fd 1 back before reading: while it still points at the pipe, the
    // pipe has a live writer and reading to EOF would block forever.
    dup2(originalStdout, 1)
    close(originalStdout)
    pipe.fileHandleForWriting.closeFile()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    return String(data: data, encoding: .utf8) ?? ""
}
