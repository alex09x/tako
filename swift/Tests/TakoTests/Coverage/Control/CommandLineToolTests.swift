/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import Foundation
import Testing
@testable import Tako

@MainActor
struct CommandLineToolTests {
    private func temp() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func installedOnlyWhenALinkRunsThisCopy() throws {
        let bin = try temp(), other = try temp()
        defer { try? FileManager.default.removeItem(atPath: bin); try? FileManager.default.removeItem(atPath: other) }
        let bundled = "/Applications/Tako.app/Contents/MacOS/takoctl"
        #expect(!CommandLineTool.isInstalled(bundled: bundled, directories: [bin]))
        try FileManager.default.createSymbolicLink(atPath: "\(bin)/takoctl", withDestinationPath: "/Old/Tako.app/Contents/MacOS/takoctl")
        #expect(!CommandLineTool.isInstalled(bundled: bundled, directories: [bin]))
        try FileManager.default.removeItem(atPath: "\(bin)/takoctl")
        try FileManager.default.createSymbolicLink(atPath: "\(other)/takoctl", withDestinationPath: bundled)
        #expect(CommandLineTool.isInstalled(bundled: bundled, directories: [bin, other]))
    }

    /// A fake app at `dir/name.app` carrying `takoctl`, saying it is `id`.
    private func app(_ dir: String, _ name: String, id: String) throws -> String {
        let macos = "\(dir)/\(name).app/Contents/MacOS"
        try FileManager.default.createDirectory(atPath: macos, withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleExecutable": name], format: .xml, options: 0)
        FileManager.default.createFile(atPath: "\(dir)/\(name).app/Contents/Info.plist", contents: plist)
        FileManager.default.createFile(atPath: "\(macos)/takoctl", contents: Data())
        return "\(macos)/takoctl"
    }

    @Test func neverReplacesAFileThatIsNotALink() throws {
        let bin = try temp(), free = try temp(), apps = try temp()
        defer { for d in [bin, free, apps] { try? FileManager.default.removeItem(atPath: d) } }
        let link = "\(bin)/takoctl"
        FileManager.default.createFile(atPath: link, contents: Data("real".utf8))
        #expect(CommandLineTool.writableDirectory(directories: ["/nonexistent", bin, free]) == free)
        try FileManager.default.removeItem(atPath: link)
        // Another tool's link, one laid out like an app bundle but not Tako,
        // and one to a Tako that is gone: all left alone.
        for target in ["/usr/lib/other/takoctl",
                       try app(apps, "Impostor", id: "com.example.impostor"),
                       "/Gone/Tako.app/Contents/MacOS/takoctl"] {
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
            #expect(CommandLineTool.occupant(link) == .other, "\(target)")
            #expect(CommandLineTool.writableDirectory(directories: [bin, free]) == free)
            #expect(CommandLineTool.occupied(directories: [bin, free]) == link)
            try FileManager.default.removeItem(atPath: link)
        }
        // A Tako's own copy -- the release or a local build -- is taken.
        for id in ["com.tako-core.terminal", "com.tako-core.terminal.demo"] {
            let target = try app(apps, id, id: id)
            try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
            #expect(CommandLineTool.occupant(link) == .tako(target: target))
            #expect(CommandLineTool.writableDirectory(directories: [bin, free]) == bin)
            #expect(CommandLineTool.occupied(directories: [bin, free]) == nil)
            try FileManager.default.removeItem(atPath: link)
        }
    }

    @Test func installLinksIntoWritableDirectoryAndReplacesTakoLink() throws {
        let bin = try temp(), apps = try temp()
        defer { try? FileManager.default.removeItem(atPath: bin); try? FileManager.default.removeItem(atPath: apps) }
        let bundled = try app(apps, "Tako", id: "com.tako-core.terminal")
        let linkPath = "\(bin)/takoctl"

        // Successful installation into a clean directory
        let installed = CommandLineTool.install(bundled: bundled, directories: [bin])
        #expect(installed == linkPath)
        #expect(CommandLineTool.isInstalled(bundled: bundled, directories: [bin]))

        // Reinstalling replaces existing Tako link
        let reinstalled = CommandLineTool.install(bundled: bundled, directories: [bin])
        #expect(reinstalled == linkPath)
        #expect(CommandLineTool.isInstalled(bundled: bundled, directories: [bin]))
    }

    @Test func installRefusesToOverwriteForeignFileOrLink() throws {
        let bin = try temp(), apps = try temp()
        defer { try? FileManager.default.removeItem(atPath: bin); try? FileManager.default.removeItem(atPath: apps) }
        let bundled = try app(apps, "Tako", id: "com.tako-core.terminal")
        let linkPath = "\(bin)/takoctl"

        // Regular file from another tool
        FileManager.default.createFile(atPath: linkPath, contents: Data("other".utf8))
        #expect(CommandLineTool.install(bundled: bundled, directories: [bin]) == nil)
        #expect(!CommandLineTool.isInstalled(bundled: bundled, directories: [bin]))

        // Foreign symlink
        try FileManager.default.removeItem(atPath: linkPath)
        try FileManager.default.createSymbolicLink(atPath: linkPath, withDestinationPath: "/usr/bin/python3")
        #expect(CommandLineTool.install(bundled: bundled, directories: [bin]) == nil)
        #expect(!CommandLineTool.isInstalled(bundled: bundled, directories: [bin]))
    }
}
