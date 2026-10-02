import Foundation
import Testing
@testable import Tako

/// A registry and a fake bundled runtime in a directory of their own.
private struct Fixture {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("tako-runtime-\(UUID().uuidString)", isDirectory: true)
    var registry: SessionRuntimeRegistry { SessionRuntimeRegistry(root: dir.appendingPathComponent("support")) }

    func helper(_ bytes: String) throws -> (SessionRuntimeRegistry.Manifest, URL) {
        let url = dir.appendingPathComponent("bundle-\(UUID().uuidString)/zmx")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let manifest = SessionRuntimeRegistry.Manifest(
            name: "zmx", version: "0.8.1", commit: "8bab1f0",
            sha256: try SessionRuntimeRegistry.sha256(of: url))
        return (manifest, url)
    }

    func tearDown() { try? FileManager.default.removeItem(at: dir) }
}

@Suite
struct SessionRuntimeTests {
    @Test func installsOnceAndFindsItByIdAlone() throws {
        let f = Fixture()
        defer { f.tearDown() }
        let (manifest, helper) = try f.helper("runtime v1")

        let id = try f.registry.install(manifest: manifest, from: helper)
        #expect(id == "0.8.1-\(manifest.sha256.prefix(16))")
        #expect(try f.registry.install(manifest: manifest, from: helper) == id)

        let exe = try f.registry.executable(for: id)
        #expect(try String(contentsOf: exe, encoding: .utf8) == "runtime v1")
        #expect(FileManager.default.isExecutableFile(atPath: exe.path))
        #expect(f.registry.installed() == [id])
    }

    @Test func anUpdateAddsAVersionAndKeepsTheOldOne() throws {
        let f = Fixture()
        defer { f.tearDown() }
        let (old, oldHelper) = try f.helper("runtime v1")
        var (new, newHelper) = try f.helper("runtime v2")
        new.version = "0.9.0"

        let oldID = try f.registry.install(manifest: old, from: oldHelper)
        let newID = try f.registry.install(manifest: new, from: newHelper)

        #expect(oldID != newID)
        #expect(f.registry.installed() == [oldID, newID].sorted())
        #expect(try String(contentsOf: f.registry.executable(for: oldID), encoding: .utf8) == "runtime v1")
    }

    @Test func aBundledFileThatDoesNotMatchItsManifestIsRefused() throws {
        let f = Fixture()
        defer { f.tearDown() }
        let (manifest, helper) = try f.helper("runtime v1")
        try Data("something else".utf8).write(to: helper)

        #expect(throws: SessionRuntimeRegistry.Failure.bundledMismatch) {
            try f.registry.install(manifest: manifest, from: helper)
        }
        // Nothing half-installed is left where a session would look.
        #expect(f.registry.installed().allSatisfy { id in
            (try? f.registry.executable(for: id)) == nil
        })
    }

    @Test func anInstalledRuntimeThatChangedIsNotRun() throws {
        let f = Fixture()
        defer { f.tearDown() }
        let (manifest, helper) = try f.helper("runtime v1")
        let id = try f.registry.install(manifest: manifest, from: helper)
        try Data("swapped".utf8).write(to: f.registry.executable(for: id))

        #expect(throws: SessionRuntimeRegistry.Failure.tampered(id)) {
            try f.registry.executable(for: id)
        }
    }

    @Test func anUnknownIdIsMissing() throws {
        let f = Fixture()
        defer { f.tearDown() }
        #expect(throws: SessionRuntimeRegistry.Failure.missing("0.8.1-0000000000000000")) {
            try f.registry.executable(for: "0.8.1-0000000000000000")
        }
    }

    @Test func aBundleWithoutARuntimeSaysSo() throws {
        let f = Fixture()
        defer { f.tearDown() }
        #expect(throws: SessionRuntimeRegistry.Failure.notBundled) {
            try SessionRuntimeRegistry.bundled(in: f.dir)
        }
    }

    @Test func idsAndVersionsThatCouldLeaveTheRegistryAreRefused() throws {
        let f = Fixture()
        defer { f.tearDown() }
        for id in ["../../outside/0.8.1-0123456789abcdef", "0.8.1/x-0123456789abcdef", "..-0123456789abcdef",
                   "0.8.1-0123456789ABCDEF", "0.8.1-short", ""] {
            #expect(throws: SessionRuntimeRegistry.Failure.invalid(id)) { try f.registry.executable(for: id) }
        }
        var (manifest, helper) = try f.helper("runtime v1")
        manifest.version = "../../outside/0.8.1"
        #expect(throws: SessionRuntimeRegistry.Failure.invalid(manifest.version)) {
            try f.registry.install(manifest: manifest, from: helper)
        }
    }

    @Test func aRuntimeDirectoryThatIsALinkIsNotFollowed() throws {
        let f = Fixture()
        defer { f.tearDown() }
        let (manifest, helper) = try f.helper("runtime v1")
        let elsewhere = f.dir.appendingPathComponent("elsewhere", isDirectory: true)
        let real = SessionRuntimeRegistry(root: elsewhere)
        let id = try real.install(manifest: manifest, from: helper)
        try FileManager.default.createDirectory(at: f.registry.runtimes, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: f.registry.runtimes.appendingPathComponent(id), withDestinationURL: real.runtimes.appendingPathComponent(id))

        #expect(throws: SessionRuntimeRegistry.Failure.missing(id)) { try f.registry.executable(for: id) }
        // Installing replaces the link with a real entry of its own.
        #expect(try f.registry.install(manifest: manifest, from: helper) == id)
        #expect(try f.registry.executable(for: id).path.hasPrefix(f.registry.runtimes.path))
    }

    @Test func aBrokenEntryIsReportedThenRepairedByInstalling() throws {
        let f = Fixture()
        defer { f.tearDown() }
        let (manifest, helper) = try f.helper("runtime v1")
        let id = try f.registry.install(manifest: manifest, from: helper)
        let dir = f.registry.runtimes.appendingPathComponent(id)

        try Data("not json".utf8).write(to: dir.appendingPathComponent("manifest.json"))
        #expect(throws: SessionRuntimeRegistry.Failure.tampered(id)) { try f.registry.executable(for: id) }
        #expect(try f.registry.install(manifest: manifest, from: helper) == id)
        #expect((try? f.registry.executable(for: id)) != nil)

        try FileManager.default.removeItem(at: dir.appendingPathComponent("manifest.json"))
        #expect(throws: SessionRuntimeRegistry.Failure.missing(id)) { try f.registry.executable(for: id) }
        #expect(try f.registry.install(manifest: manifest, from: helper) == id)
        #expect((try? f.registry.executable(for: id)) != nil)
    }

    @Test func aRuntimeThatLostItsExecuteBitIsNotRun() throws {
        let f = Fixture()
        defer { f.tearDown() }
        let (manifest, helper) = try f.helper("runtime v1")
        let id = try f.registry.install(manifest: manifest, from: helper)
        let exe = f.registry.runtimes.appendingPathComponent(id).appendingPathComponent("zmx")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: exe.path)

        #expect(throws: SessionRuntimeRegistry.Failure.tampered(id)) { try f.registry.executable(for: id) }
        #expect(try f.registry.install(manifest: manifest, from: helper) == id)
        #expect(FileManager.default.isExecutableFile(atPath: try f.registry.executable(for: id).path))
    }
}
