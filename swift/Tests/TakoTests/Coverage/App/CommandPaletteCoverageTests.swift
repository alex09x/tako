import Testing
import AppKit
import SwiftUI
@testable import Tako

@MainActor
private func makeHostedWindow(size: NSSize = .init(width: 520, height: 420)) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled],
        backing: .buffered,
        defer: false)
    window.isReleasedWhenClosed = false
    return window
}

/// Hosts `view` in a real window and forces a layout pass, so the SwiftUI
/// body of `CommandPaletteView` and its private nested views (`CommandTable`,
/// `CommandRow`, `CommandPaletteQuery`, `ShortcutSymbolsView`) actually run --
/// those are declared `private` to CommandPalette.swift, so hosting is the
/// only way this test file can exercise their bodies at all.
@MainActor
@discardableResult
private func host<V: View>(_ view: V, in window: NSWindow) -> NSHostingView<V> {
    let hosting = NSHostingView(rootView: view)
    hosting.frame = NSRect(origin: .zero, size: window.frame.size)
    window.contentView = hosting
    window.orderFrontRegardless()
    hosting.layoutSubtreeIfNeeded()
    hosting.displayIfNeeded()
    return hosting
}

struct CommandOptionTests {
    @Test func initStoresAllFieldsAndActionIsInvokable() {
        var invoked = false
        let option = CommandOption(
            title: "Title",
            subtitle: "Sub",
            description: "Desc",
            symbols: ["⌘", "K"],
            leadingIcon: "star",
            leadingColor: .red,
            badge: "NEW",
            emphasis: true,
            sortKey: AnySortKey(0)
        ) { invoked = true }

        option.action()

        #expect(invoked)
        #expect(option.title == "Title")
        #expect(option.subtitle == "Sub")
        #expect(option.description == "Desc")
        #expect(option.symbols == ["⌘", "K"])
        #expect(option.leadingIcon == "star")
        #expect(option.badge == "NEW")
        #expect(option.emphasis)
        #expect(option.sortKey != nil)
    }

    @Test func minimalInitUsesDefaults() {
        let option = CommandOption(title: "Only") {}
        #expect(option.subtitle == nil)
        #expect(option.description == nil)
        #expect(option.symbols == nil)
        #expect(option.leadingIcon == nil)
        #expect(option.leadingColor == nil)
        #expect(option.badge == nil)
        #expect(!option.emphasis)
        #expect(option.sortKey == nil)
    }

    @Test func equalityAndHashAreIdentityBased() {
        let a = CommandOption(title: "A") {}
        let b = CommandOption(title: "A") {}
        #expect(a == a)
        #expect(a != b)

        var hasher = Hasher()
        a.hash(into: &hasher)
        #expect(hasher.finalize() == hasher.finalize())
    }
}

struct StringMatchedIndicesTests {
    @Test func substringMatchReturnsContiguousRange() {
        let indices = "Reload Config".matchedIndices(for: "load")
        #expect(indices?.count == 4)
    }

    @Test func initialsMatchFallsBackWhenNoSubstringMatches() {
        let indices = "New Window".matchedIndices(for: "nw")
        #expect(indices?.count == 2)
    }

    @Test func noMatchReturnsNil() {
        #expect("Hello".matchedIndices(for: "zzz") == nil)
    }

    @Test func emptyQueryReturnsNil() {
        #expect("Hello".matchedIndices(for: "") == nil)
    }

    @Test func partialInitialsMatchFails() {
        #expect("New Window".matchedIndices(for: "nx") == nil)
    }

    @Test func caseInsensitiveSubstringMatch() {
        #expect("HELLO WORLD".matchedIndices(for: "hello") != nil)
    }
}

@MainActor
struct CommandPaletteViewLogicTests {
    @Test func queryTrimsWhitespace() {
        let view = CommandPaletteView(
            isPresented: .constant(true), options: [], initialQuery: "  hi  ")
        #expect(view.query == "hi")
    }

    @Test func filteredOptionsReturnsAllUnfilteredWhenQueryEmpty() {
        let options = [CommandOption(title: "A") {}, CommandOption(title: "B") {}]
        let view = CommandPaletteView(isPresented: .constant(true), options: options)
        #expect(view.filteredOptions.count == 2)
    }

    @Test func filteredOptionsMatchesByTitle() {
        let options = [
            CommandOption(title: "Reload Config") {},
            CommandOption(title: "New Window") {},
        ]
        let view = CommandPaletteView(
            isPresented: .constant(true), options: options, initialQuery: "reload")
        #expect(view.filteredOptions.map(\.title) == ["Reload Config"])
    }

    @Test func filteredOptionsMatchesBySubtitleWhenTitleDoesNotMatch() {
        let options = [
            CommandOption(title: "Focus: Terminal", subtitle: "project-alpha") {},
            CommandOption(title: "Focus: Other", subtitle: "project-beta") {},
        ]
        let view = CommandPaletteView(
            isPresented: .constant(true), options: options, initialQuery: "alpha")
        #expect(view.filteredOptions.map(\.title) == ["Focus: Terminal"])
    }

    @Test func filteredOptionsRanksCloseColorMatchesFirst() {
        let options = [
            CommandOption(title: "Unrelated", leadingColor: .black) {},
            CommandOption(title: "Also Unrelated", leadingColor: .red) {},
        ]
        let view = CommandPaletteView(
            isPresented: .constant(true), options: options, initialQuery: "red")
        // The red option should match via color score even though neither
        // title nor subtitle contains "red", and it should sort first.
        #expect(view.filteredOptions.first?.title == "Also Unrelated")
    }

    @Test func filteredOptionsExcludesOptionsWithNoMatchAtAll() {
        let options = [
            CommandOption(title: "Alpha") {},
            CommandOption(title: "Beta") {},
        ]
        let view = CommandPaletteView(
            isPresented: .constant(true), options: options, initialQuery: "zzz")
        #expect(view.filteredOptions.isEmpty)
    }

    @Test func selectedOptionIsNilWithoutSelection() {
        let options = [CommandOption(title: "A") {}]
        let view = CommandPaletteView(isPresented: .constant(true), options: options)
        #expect(view.selectedOption == nil)
    }

    @Test func selectedOptionReturnsOptionAtIndex() {
        let options = [CommandOption(title: "A") {}, CommandOption(title: "B") {}]
        let view = CommandPaletteView(
            isPresented: .constant(true), options: options, initialSelectedIndex: 1)
        #expect(view.selectedOption?.title == "B")
    }

    @Test func selectedOptionFallsBackToLastWhenIndexIsOutOfRange() {
        let options = [CommandOption(title: "A") {}, CommandOption(title: "B") {}]
        let view = CommandPaletteView(
            isPresented: .constant(true), options: options, initialSelectedIndex: 99)
        #expect(view.selectedOption?.title == "B")
    }
}

@MainActor
struct CommandPaletteRenderingTests {
    @Test func rendersRowsWithIconsBadgesSymbolsAndColorSwatches() {
        let window = makeHostedWindow()
        defer { window.close() }

        let options = [
            CommandOption(
                title: "Focus: Alpha",
                subtitle: "/tmp/alpha",
                description: "Jump to Alpha",
                symbols: ["⌘", "1"],
                leadingIcon: "rectangle.on.rectangle",
                leadingColor: .green,
                badge: "TAB",
                emphasis: true
            ) {},
            CommandOption(title: "Reload Config", description: "Reloads the config") {},
        ]

        let hosting = host(
            CommandPaletteView(
                isPresented: .constant(true), options: options, initialSelectedIndex: 0),
            in: window)

        #expect(hosting.rootView.filteredOptions.count == 2)
    }

    @Test func rendersNoMatchesStateWithEmptyOptions() {
        let window = makeHostedWindow()
        defer { window.close() }

        let hosting = host(
            CommandPaletteView(isPresented: .constant(true), options: []), in: window)

        #expect(hosting.rootView.filteredOptions.isEmpty)
    }

    @Test func rendersHighlightedMatchesWhenQueryIsNonEmpty() {
        let window = makeHostedWindow()
        defer { window.close() }

        let options = [
            CommandOption(title: "Reload Config", subtitle: "reload the config file") {},
        ]

        let hosting = host(
            CommandPaletteView(
                isPresented: .constant(true), options: options, initialQuery: "reload"),
            in: window)

        #expect(hosting.rootView.filteredOptions.count == 1)
    }
}
