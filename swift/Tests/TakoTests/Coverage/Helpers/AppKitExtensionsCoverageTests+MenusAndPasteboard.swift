/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Testing
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TakoKit
@testable import Tako

@MainActor

@MainActor
struct NSMenuExtensionTests {
    @Test func insertItemAfterActionInsertsAtCorrectIndex() {
        let menu = NSMenu()
        let first = NSMenuItem(title: "First", action: #selector(NSObject.description), keyEquivalent: "")
        let second = NSMenuItem(title: "Second", action: nil, keyEquivalent: "")
        menu.addItem(first)

        let inserted = NSMenuItem(title: "Inserted", action: nil, keyEquivalent: "")
        let index = menu.insertItem(inserted, after: #selector(NSObject.description))
        #expect(index == 1)
        #expect(menu.items[1] === inserted)

        menu.addItem(second)
        _ = second
    }

    @Test func insertItemAfterMissingActionReturnsNil() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Only", action: nil, keyEquivalent: ""))
        let inserted = NSMenuItem(title: "Inserted", action: nil, keyEquivalent: "")
        let index = menu.insertItem(inserted, after: #selector(NSObject.copy as () -> Any))
        #expect(index == nil)
        #expect(!menu.items.contains(where: { $0 === inserted }))
    }

    @Test func insertItemAfterRemovesExistingDuplicateIdentifierFirst() {
        let menu = NSMenu()
        let anchor = NSMenuItem(title: "Anchor", action: #selector(NSObject.description), keyEquivalent: "")
        menu.addItem(anchor)

        let identifier = NSUserInterfaceItemIdentifier("dup")
        let original = NSMenuItem(title: "Original", action: nil, keyEquivalent: "")
        original.identifier = identifier
        menu.addItem(original)

        let replacement = NSMenuItem(title: "Replacement", action: nil, keyEquivalent: "")
        replacement.identifier = identifier
        _ = menu.insertItem(replacement, after: #selector(NSObject.description))

        #expect(menu.items.filter { $0.identifier == identifier }.count == 1)
        #expect(menu.items.contains(where: { $0 === replacement }))
        #expect(!menu.items.contains(where: { $0 === original }))
    }

    @Test func removeItemsWithIdentifiersRemovesMatchingItemsOnly() {
        let menu = NSMenu()
        let keep = NSMenuItem(title: "Keep", action: nil, keyEquivalent: "")
        keep.identifier = NSUserInterfaceItemIdentifier("keep")
        let dropA = NSMenuItem(title: "DropA", action: nil, keyEquivalent: "")
        dropA.identifier = NSUserInterfaceItemIdentifier("drop-a")
        let dropB = NSMenuItem(title: "DropB", action: nil, keyEquivalent: "")
        dropB.identifier = NSUserInterfaceItemIdentifier("drop-b")

        menu.addItem(keep)
        menu.addItem(dropA)
        menu.addItem(dropB)

        menu.removeItems(withIdentifiers: [dropA.identifier!, dropB.identifier!])

        #expect(menu.items == [keep])
    }
}

// MARK: NSPasteboard+Extension

@MainActor
struct NSPasteboardExtensionAdditionalTests {
    @Test func mimeTypeInitHandlesUnregisteredMimeType() {
        // UTType(mimeType:) dynamically synthesizes a type for unknown MIME
        // strings on modern macOS, so this exercises the general utType.identifier
        // path (the raw-identifier fallback below it only fires if that ever
        // returns nil); either way the result must be non-nil and usable.
        let type = NSPasteboard.PasteboardType(mimeType: "application/x-tako-totally-made-up")
        #expect(type != nil)
    }

    @Test func takoSelectsGeneralPasteboardForStandardClipboard() {
        #expect(NSPasteboard.tako(TAKO_CLIPBOARD_STANDARD) === NSPasteboard.general)
    }

    @Test func takoSelectsSelectionPasteboardForSelectionClipboard() {
        #expect(NSPasteboard.tako(TAKO_CLIPBOARD_SELECTION) === NSPasteboard.takoSelection)
    }

    @Test func opinionatedContentsReturnsNilWhenPasteboardEmpty() {
        let pasteboard = NSPasteboard(name: .init("test-empty-\(UUID().uuidString)"))
        pasteboard.clearContents()
        #expect(pasteboard.getOpinionatedStringContents() == nil)
    }

    @Test func opinionatedContentsEscapesFileURLPath() {
        let pasteboard = NSPasteboard(name: .init("test-file-\(UUID().uuidString)"))
        pasteboard.clearContents()

        let item = NSPasteboardItem()
        let url = URL(fileURLWithPath: "/tmp/has space/file.txt")
        item.setString((url as NSURL).absoluteString ?? url.absoluteString, forType: .fileURL)
        pasteboard.writeObjects([item])

        let result = pasteboard.getOpinionatedStringContents()
        #expect(result != nil)
        #expect(result?.contains("has\\ space") == true || result?.contains("\\ ") == true)
    }
}

// MARK: OSPasteboard+Extension

@MainActor
struct OSPasteboardExtensionTests {
    @MainActor
    @Test func stringGetterReflectsSetter() {
        let pasteboard = NSPasteboard(name: .init("test-osstring-\(UUID().uuidString)"))
        pasteboard.string = "hello os pasteboard"
        #expect(pasteboard.string == "hello os pasteboard")
    }

    @MainActor
    @Test func stringSetterWithNilClearsContents() {
        let pasteboard = NSPasteboard(name: .init("test-osstring-nil-\(UUID().uuidString)"))
        pasteboard.string = "content"
        pasteboard.string = nil
        #expect(pasteboard.string == nil)
    }

    @MainActor
    @Test func findPasteboardIsAccessible() {
        #expect(OSPasteboard.find.name == .find)
    }
}

// MARK: NSWorkspace+Extension

@MainActor
struct NSWorkspaceExtensionTests {
    @Test func defaultApplicationURLForExtensionResolvesTextFiles() {
        let url = NSWorkspace.shared.defaultApplicationURL(forExtension: "txt")
        #expect(url == nil || url?.isFileURL == true)
    }

    @Test func defaultApplicationURLForUnknownExtensionIsNilOrFile() {
        let url = NSWorkspace.shared.defaultApplicationURL(forExtension: "definitely-not-a-real-ext-xyz")
        #expect(url == nil)
    }

    @Test func defaultTextEditorAndTerminalAreQueriable() {
        // We can't assert a specific app is installed on the CI machine, but the
        // computed properties must route through defaultApplicationURL(forContentType:)
        // without crashing and return a file URL when present.
        let editor = NSWorkspace.shared.defaultTextEditor
        #expect(editor == nil || editor?.isFileURL == true)

        let terminal = NSWorkspace.shared.defaultTerminal
        #expect(terminal == nil || terminal?.isFileURL == true)
    }
}

// MARK: NSImage+Extension

@MainActor
struct NSImageExtensionTests {
    private func solidImage(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }

    @Test func combineRequiresMatchingCounts() {
        let image = solidImage(size: .init(width: 4, height: 4), color: .red)
        let result = NSImage.combine(images: [image], blendingModes: [.normal, .multiply])
        #expect(result == nil)
    }

    @Test func combineRequiresNonEmptyInput() {
        let result = NSImage.combine(images: [], blendingModes: [])
        #expect(result == nil)
    }

    @Test func combineProducesImageOfFirstImageSize() {
        let a = solidImage(size: .init(width: 8, height: 8), color: .red)
        let b = solidImage(size: .init(width: 8, height: 8), color: .blue)
        let combined = NSImage.combine(images: [a, b], blendingModes: [.normal, .multiply])
        #expect(combined?.size == NSSize(width: 8, height: 8))
    }

    @Test func gradientProducesNonNilImage() {
        let base = solidImage(size: .init(width: 10, height: 10), color: .black)
        let result = base.gradient(colors: [.red, .blue])
        #expect(result != nil)
        #expect(result?.size == base.size)
    }

    @Test func tintProducesImageOfSameSize() {
        let base = solidImage(size: .init(width: 6, height: 6), color: .white)
        let tinted = base.tint(color: .green)
        #expect(tinted != nil)
        #expect(tinted?.size == base.size)
    }
}

// MARK: NSScreen+Extension (hasDock / hasNotch / displayID via controllable mocks)
