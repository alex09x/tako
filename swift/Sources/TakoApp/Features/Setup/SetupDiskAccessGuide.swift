// Tako — Full Disk Access application picker guide
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
    @Environment(\.dismiss) private var dismiss
    let openSettings: () -> Bool
    @State private var feedback: String?
    private let appURL = Bundle.main.bundleURL

    var body: some View {
        VStack(spacing: 18) {
            Text("Add Tako to Full Disk Access").font(.system(size: 21, weight: .semibold))
            Text("Drag this app into the list in Settings, then turn its switch on.")
                .multilineTextAlignment(.center).foregroundStyle(colors.muted)
            HStack(spacing: 12) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 4) {
                    Text(appURL.deletingPathExtension().lastPathComponent).fontWeight(.semibold)
                    Text("Drag into Full Disk Access").font(.system(size: 12)).foregroundStyle(colors.muted)
                }
                Image(systemName: "arrow.up.right").foregroundStyle(colors.muted)
            }
            .padding(16).frame(maxWidth: .infinity)
            .background(colors.text.opacity(0.05), in: .rect(cornerRadius: 10))
            .contentShape(Rectangle())
            .onDrag { SetupAppDragItem.make(url: appURL) }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Drag \(appURL.lastPathComponent) into Full Disk Access")
            .accessibilityIdentifier("SetupDiskDragApp")
            Button("Open Full Disk Access") {
                if !openSettings() { feedback = "macOS Settings couldn't be opened." }
            }
            .buttonStyle(SetupButtonStyle(primary: true))
            .accessibilityIdentifier("SetupDiskOpenSettings")
            Text("Or press + in Settings, press ⇧⌘G and paste this app path:")
                .font(.system(size: 12)).foregroundStyle(colors.muted)
            Text(appURL.path).font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("SetupDiskAppPath")
            HStack {
                Button("Copy app path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appURL.path, forType: .string)
                    feedback = "App path copied."
                }
                .accessibilityIdentifier("SetupDiskCopyPath")
                Button("Show app in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([appURL])
                }
            }.buttonStyle(SetupButtonStyle())
            if let feedback { Text(feedback).font(.system(size: 12)).foregroundStyle(colors.message) }
            Button("Back") { dismiss() }.buttonStyle(SetupButtonStyle())
                .keyboardShortcut(.cancelAction).accessibilityIdentifier("SetupDiskGuideBack")
        }
        .font(.system(size: 13)).foregroundStyle(colors.text)
        .padding(24).frame(width: 460).background(colors.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SetupDiskAccessGuide")
    }
}
