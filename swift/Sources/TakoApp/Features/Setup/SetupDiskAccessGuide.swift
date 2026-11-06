// Tako — inline Full Disk Access app identity
// Copyright (c) 2026 Alexander Panasenko
// Contact: alex@prod.codes
// Author: https://prod.codes/about/
// Project: https://github.com/alex09x/tako
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SetupAppDragItem {
    static func make(url: URL = Bundle.main.bundleURL) -> NSItemProvider {
        NSItemProvider(item: url as NSURL, typeIdentifier: UTType.fileURL.identifier)
    }
}

@MainActor
struct SetupDiskAccessGuide: View {
    @Environment(\.setupPalette) private var colors
    private let appURL = Bundle.main.bundleURL

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(appURL.deletingPathExtension().lastPathComponent).font(.system(size: 13, weight: .semibold))
                Text("Drag this app into Full Disk Access, then enable it.")
                    .font(.system(size: 12)).foregroundStyle(colors.muted)
                Text("Reopen only if macOS asks.")
                    .font(.system(size: 11)).foregroundStyle(colors.muted)
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").foregroundStyle(colors.muted)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.text.opacity(0.04), in: .rect(cornerRadius: 10))
        .contentShape(Rectangle())
        .onDrag { SetupAppDragItem.make(url: appURL) }
        .contextMenu {
            Button("Copy app path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(appURL.path, forType: .string)
            }
            Button("Show app in Finder") { NSWorkspace.shared.activateFileViewerSelecting([appURL]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Drag \(appURL.lastPathComponent) into Full Disk Access")
        .accessibilityIdentifier("SetupDiskDragApp")
    }
}
