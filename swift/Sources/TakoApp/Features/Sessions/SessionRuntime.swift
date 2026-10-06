/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import CryptoKit
import Foundation

/// The session runtime (zmx) as Tako keeps it for session-persistence:
/// every version a live session may still need, each in a directory of its
/// own, checked by content before it is run.
///
/// The app bundle carries one runtime and a manifest with the SHA-256 of
/// that signed file. Installing it copies it into
/// `<root>/runtime/<id>/zmx`, where `id` is the version and the start of the
/// hash. A session records only that id; the path is always worked out here,
/// never taken from the session's own metadata. Updating the app adds a new
/// id and leaves the old ones, so sessions started by an older Tako keep
/// the runtime they need. Nothing is removed automatically.
struct SessionRuntimeRegistry {
    struct Manifest: Codable, Equatable {
        var name: String
        var version: String
        var commit: String
        var sha256: String
    }

    enum Failure: Error, Equatable {
        /// The app has no runtime, or its manifest cannot be read.
        case notBundled
        /// The bundled file does not match its own manifest.
        case bundledMismatch
        /// No runtime with this id has been installed.
        case missing(String)
        /// The installed file no longer matches what was installed.
        case tampered(String)
        /// An id or manifest that is not a plain version and hash -- never
        /// turned into a path.
        case invalid(String)
    }

    /// Where runtimes are installed: `<Application Support>/<bundle>`.
    let root: URL

    var runtimes: URL { root.appendingPathComponent("runtime", isDirectory: true) }

    static func id(for manifest: Manifest) -> String {
        "\(manifest.version)-\(manifest.sha256.prefix(16))"
    }

    /// A version is digits, letters, dots, plus and minus, at most 32, not
    /// starting with a dot; a hash is 64 lowercase hex digits. So an id is
    /// always one plain path component inside the registry.
    static func isValid(_ manifest: Manifest) -> Bool {
        isValidVersion(manifest.version) && manifest.sha256.count == 64
            && manifest.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    static func isValidVersion(_ version: String) -> Bool {
        (1...32).contains(version.count) && !version.hasPrefix(".") && !version.contains("..")
            && version.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".+-".contains($0)) }
    }

    static func isValidID(_ id: String) -> Bool {
        guard let dash = id.lastIndex(of: "-") else { return false }
        let hash = id[id.index(after: dash)...]
        return isValidVersion(String(id[..<dash])) && hash.count == 16
            && hash.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// The directory of a runtime id, and only if it is a real directory
    /// directly inside the registry -- not a symbolic link out of it.
    private func directory(for id: String) throws -> URL {
        guard Self.isValidID(id) else { throw Failure.invalid(id) }
        let dir = runtimes.appendingPathComponent(id, isDirectory: true)
        guard dir.deletingLastPathComponent().standardizedFileURL == runtimes.standardizedFileURL else {
            throw Failure.invalid(id)
        }
        return dir
    }

    private static func isPlainFile(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    private static func isPlainDirectory(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeDirectory
    }

    /// Whether `dir` holds exactly this runtime: its record matches, the
    /// executable is a plain executable file with the recorded hash.
    private static func entryIsValid(_ dir: URL, _ manifest: Manifest) -> Bool {
        let target = dir.appendingPathComponent("zmx")
        let recordURL = dir.appendingPathComponent("manifest.json")
        guard isPlainDirectory(dir), isPlainFile(target), isPlainFile(recordURL),
              FileManager.default.isExecutableFile(atPath: target.path),
              let data = try? Data(contentsOf: recordURL),
              let record = try? JSONDecoder().decode(Manifest.self, from: data),
              record == manifest
        else { return false }
        return (try? sha256(of: target)) == manifest.sha256
    }

    static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The runtime inside an app bundle, as its manifest describes it.
    static func bundled(in bundle: URL) throws -> (manifest: Manifest, executable: URL) {
        let manifestURL = bundle.appendingPathComponent("Contents/Resources/session-runtime.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { throw Failure.notBundled }
        let executable = bundle.appendingPathComponent("Contents/Helpers/zmx")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw Failure.notBundled }
        return (manifest, executable)
    }

    /// Installs the bundled runtime if it is not already, and returns its id.
    /// The copy lands under a temporary name and is renamed into place only
    /// after its hash checks out, so a crash never leaves a partial runtime
    /// where a session would find it.
    /// An entry already there is reused only if it is complete and right
    /// in every part; anything else in its place is replaced as a whole.
    @discardableResult
    func install(manifest: Manifest, from executable: URL) throws -> String {
        guard Self.isValid(manifest) else { throw Failure.invalid(manifest.version) }
        guard try Self.sha256(of: executable) == manifest.sha256 else { throw Failure.bundledMismatch }
        let id = Self.id(for: manifest)
        let dir = try directory(for: id)
        if Self.entryIsValid(dir, manifest) { return id }

        // The whole entry is assembled beside the registry's entries and
        // moved in by renaming, so no lookup ever sees half of it.
        let fm = FileManager.default
        try fm.createDirectory(at: runtimes, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let staging = runtimes.appendingPathComponent(".\(id)-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        let stagedExe = staging.appendingPathComponent("zmx")
        try fm.copyItem(at: executable, to: stagedExe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagedExe.path)
        try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        guard Self.entryIsValid(staging, manifest) else { throw Failure.bundledMismatch }
        // Whatever stood there (a broken entry, a link) is renamed aside
        // first -- not followed, not merged -- and removed after. In between
        // a lookup finds nothing and says the runtime is missing, never
        // something wrong.
        if (try? fm.attributesOfItem(atPath: dir.path)) != nil {
            let old = runtimes.appendingPathComponent(".\(id)-old-\(UUID().uuidString)")
            try fm.moveItem(at: dir, to: old)
            defer { try? fm.removeItem(at: old) }
            try fm.moveItem(at: staging, to: dir)
        } else {
            try fm.moveItem(at: staging, to: dir)
        }
        return id
    }

    /// The executable of an installed runtime, after checking it is still
    /// the file that was installed.
    func executable(for id: String) throws -> URL {
        let dir = try directory(for: id)
        guard Self.isPlainDirectory(dir),
              let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json"))
        else { throw Failure.missing(id) }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              Self.isValid(manifest), Self.id(for: manifest) == id,
              Self.entryIsValid(dir, manifest)
        else { throw Failure.tampered(id) }
        return dir.appendingPathComponent("zmx")
    }

    /// The ids of every installed runtime.
    func installed() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: runtimes.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }
}
