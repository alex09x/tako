// Tako — application URL transfer regression tests
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import AppKit
import Testing
import UniformTypeIdentifiers
@testable import Tako

@Suite @MainActor
struct SetupAppDragItemTests {
    @Test func transfersTheAppFileURLIncludingSpaces() async {
        let url = URL(fileURLWithPath: "/Applications/Permission Fixture.app", isDirectory: true)
        let provider = SetupAppDragItem.make(url: url)
        #expect(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        let path = await transferredPath(provider)
        #expect(path == url.path)
    }

    @Test func defaultTransferUsesThisRunningBundle() async {
        let path = await transferredPath(SetupAppDragItem.make())
        #expect(path == Bundle.main.bundleURL.path)
    }

    private func transferredPath(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, _ in
                if let url = value as? URL { continuation.resume(returning: url.path) }
                else if let data = value as? Data,
                        let string = String(data: data, encoding: .utf8), let url = URL(string: string) {
                    continuation.resume(returning: url.path)
                } else { continuation.resume(returning: nil) }
            }
        }
    }
}
