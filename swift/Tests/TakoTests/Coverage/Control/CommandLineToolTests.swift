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

    @Test func neverReplacesAFileThatIsNotALink() throws {
        let bin = try temp(), free = try temp()
        defer { try? FileManager.default.removeItem(atPath: bin); try? FileManager.default.removeItem(atPath: free) }
        FileManager.default.createFile(atPath: "\(bin)/takoctl", contents: Data("real".utf8))
        #expect(CommandLineTool.writableDirectory(directories: ["/nonexistent", bin, free]) == free)
        try FileManager.default.removeItem(atPath: "\(bin)/takoctl")
        try FileManager.default.createSymbolicLink(atPath: "\(bin)/takoctl", withDestinationPath: "/old")
        #expect(CommandLineTool.writableDirectory(directories: [bin, free]) == bin)
    }
}
