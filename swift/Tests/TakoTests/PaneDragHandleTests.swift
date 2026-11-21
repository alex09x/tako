// tako — Split pane drag completion tests
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import AppKit
import CoreTransferable
import Testing
import UniformTypeIdentifiers
@testable import Tako

@MainActor
struct PaneDragHandleTests {
    @Test func aPaneTransferAdvertisesOnlyItsLiveIdentifier() async throws {
        let surface = Tako.SurfaceView(frame: .zero)
        defer { surface.close() }
        let provider = NSItemProvider()
        provider.register(surface)
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.takoSurfaceId.identifier))
        let data = try await withCheckedThrowingContinuation { (reply: CheckedContinuation<Data, Error>) in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.takoSurfaceId.identifier) { data, error in
                if let data { reply.resume(returning: data) }
                else { reply.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        #expect(String(data: data, encoding: .utf8) == surface.id.uuidString)
    }

    @Test func anOutsideReleaseDetachesAtThePointerAndClearsDragging() {
        let view = PaneDragHandleView(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        var position: NSPoint?
        var dragging = true
        view.detach = { position = $0 }
        view.draggingChanged = { dragging = $0 }
        view.completeDrag(at: NSPoint(x: 450, y: 300), operation: [], mouseButtons: 0)
        #expect(position == NSPoint(x: 450, y: 300))
        #expect(!dragging)
    }

    @Test func aRejectedReleaseInsideItsSourceWindowStaysInPlace() {
        let view = PaneDragHandleView(frame: .zero)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 300, height: 200),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { window.contentView = nil }
        var detached = false
        var dragging = true
        view.detach = { _ in detached = true }
        view.draggingChanged = { dragging = $0 }
        view.completeDrag(at: NSPoint(x: window.frame.midX, y: window.frame.midY),
                          operation: [], mouseButtons: 0)
        #expect(!detached)
        #expect(!dragging)
        #expect(view.window === window)
    }

    @Test func escapeCannotDetachEvenIfTheMouseIsReleased() {
        let view = PaneDragHandleView(frame: .zero)
        var detached = false
        view.detach = { _ in detached = true }
        view.cancelOperation(nil)
        view.completeDrag(at: NSPoint(x: 450, y: 300), operation: [], mouseButtons: 0)
        #expect(!detached)
    }

    @Test func aCancelledDragWithTheButtonStillHeldCannotDetach() {
        let view = PaneDragHandleView(frame: .zero)
        var detached = false
        view.detach = { _ in detached = true }
        view.completeDrag(at: NSPoint(x: 450, y: 300), operation: [], mouseButtons: 1)
        #expect(!detached)
    }

    @Test func aDropAcceptedByAnotherPaneCannotAlsoCreateAWindow() {
        let view = PaneDragHandleView(frame: .zero)
        var detached = false
        view.detach = { _ in detached = true }
        view.completeDrag(at: NSPoint(x: 450, y: 300), operation: .move, mouseButtons: 0)
        #expect(!detached)
    }
}
