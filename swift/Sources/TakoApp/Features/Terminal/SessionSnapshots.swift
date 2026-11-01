/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

import AppKit
import Foundation

/// What a tab showed when it was last saved: the terminal engine's exact
/// state, and when it was taken. It is only the emulator's side -- the shell
/// that produced it does not survive a relaunch, and a restored tab says so.
struct SessionSnapshot: Equatable {
    var savedAt: Date
    var checkpoint: Data

    /// The terminal dimensions (columns and rows) stored in the checkpoint header and payload.
    var checkpointGeometry: (cols: Int, rows: Int)? {
        guard checkpoint.count >= 28 else { return nil }
        guard checkpoint[0] == 0x54, checkpoint[1] == 0x4b, checkpoint[2] == 0x43, (checkpoint[3] == 0x4b || checkpoint[3] == 0x50) else {
            return nil
        }
        let cols = checkpoint.subdata(in: 20..<24).withUnsafeBytes { $0.load(as: UInt32.self) }
        let rows = checkpoint.subdata(in: 24..<28).withUnsafeBytes { $0.load(as: UInt32.self) }
        let c = Int(UInt32(littleEndian: cols))
        let r = Int(UInt32(littleEndian: rows))
        guard c > 0, r > 0, c < 10000, r < 10000 else { return nil }
        return (c, r)
    }

    /// Bytes fed to a restored engine, never to the shell: put the screen
    /// back in the state a fresh shell expects, below the saved text. No
    /// banner: a restored tab is what the user expects, not news.
    ///
    /// A snapshot can be taken while a full-screen program runs, so its
    /// modes come with it: mouse reporting, bracketed paste, application
    /// cursor keys, a kitty keyboard mode, a scroll region. Left in place,
    /// the new shell would receive input encoded for that program. Resetting
    /// the scroll region and origin mode homes the cursor, so it is put back
    /// at `cursorRow`/`cursorCol` (0-based, read after leaving the alternate
    /// screen) before the line is drawn below it.
    static func separator(savedAt: Date, cursorRow: UInt32, cursorCol: UInt32) -> [UInt8] {
        let reset = "\u{1b}[0m\u{1b}[r\u{1b}[?6l\u{1b}[?7h\u{1b}[?25h\u{1b}[?1l"
            + "\u{1b}[?1000l\u{1b}[?1002l\u{1b}[?1003l\u{1b}[?1005l\u{1b}[?1006l"
            + "\u{1b}[?1004l\u{1b}[?2004l\u{1b}[=0u\u{1b}[>4m"
            + "\u{1b}[\(cursorRow + 1);\(cursorCol + 1)H"
        // Below the old cursor sit rows the old shell had not reached or had
        // drawn ahead (a right prompt, a menu); they are cleared, so nothing
        // stale shows next to the new shell's output.
        let line = "\r\n\u{1b}[J"
        return Array((reset + line).utf8)
    }

    /// Leaves the alternate screen a full-screen program was on, so the
    /// shell's own screen is the one restored. Fed only when it is on:
    /// leaving otherwise would restore a saved cursor nobody asked for.
    static let leaveAlternateScreen = Array("\u{1b}[?1049l".utf8)
}

/// What a surface gave when asked for its state.
enum SnapshotExport: Equatable {
    case unchanged
    case tooLarge
    case exported(Data, generation: UInt64)
}

/// Saved tabs on disk, one file per surface id, readable only by the user.
/// Scrollback can hold anything that was printed, so it is kept local, has
/// a size limit, and is removed as soon as saving is turned off.
final class SessionSnapshotStore {
    /// Where restoring reads and the app saves. Tests point it at a
    /// temporary directory.
    nonisolated(unsafe) static var shared = SessionSnapshotStore(directory: SessionSnapshotStore.defaultDirectory)

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let bundle = Bundle.main.bundleIdentifier ?? "com.alex09x.tako"
        return base.appendingPathComponent(bundle).appendingPathComponent("Sessions", isDirectory: true)
    }

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    private static let magic = Array("TKS1".utf8)
    /// The magic and the save time in front of every checkpoint.
    static let headerSize: UInt64 = 12

    func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension("snapshot")
    }

    /// Layout: "TKS1", the save time as little-endian seconds since 1970
    /// (Float64 bits), then the checkpoint. Written atomically, mode 0600.
    func write(_ snapshot: SessionSnapshot, id: UUID) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var data = Data(Self.magic)
        withUnsafeBytes(of: snapshot.savedAt.timeIntervalSince1970.bitPattern.littleEndian) {
            data.append(contentsOf: $0)
        }
        data.append(snapshot.checkpoint)
        let target = url(for: id)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }

    func read(id: UUID) -> SessionSnapshot? {
        guard let data = try? Data(contentsOf: url(for: id)),
              data.count > 12, Array(data.prefix(4)) == Self.magic
        else { return nil }
        var bits: UInt64 = 0
        for (i, byte) in data.dropFirst(4).prefix(8).enumerated() {
            bits |= UInt64(byte) << (8 * UInt64(i))
        }
        return SessionSnapshot(
            savedAt: Date(timeIntervalSince1970: Double(bitPattern: bits)),
            checkpoint: Data(data.dropFirst(12)))
    }

    /// Bytes the saved tab takes on disk, header included.
    func size(id: UUID) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url(for: id).path)[.size] as? NSNumber)?.uint64Value
    }

    func remove(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
        removeHistory(id: id)
    }

    /// Drops every saved tab not in `ids` -- closed tabs, and windows that
    /// were not restored.
    func removeAll(except ids: Set<UUID>) {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "snapshot" {
            let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent)
            if id.map({ !ids.contains($0) }) ?? true {
                try? FileManager.default.removeItem(at: file)
            }
        }
        removeHistory(except: ids)
    }

    func removeAll() {
        removeAll(except: [])
    }
}

/// Saves every open tab periodically and once more at quit, so a crash
/// loses at most one interval.
@MainActor
final class SessionSnapshotSaver {
    static let interval: TimeInterval = 30

    struct Settings {
        var enabled: Bool
        var limit: UInt64
        var secureInput: Bool
    }

    let store: SessionSnapshotStore
    /// The parse count each tab had when it was last written.
    private var written: [UUID: UInt64] = [:]
    /// Monotonic token per pane to ensure out-of-order or stale async saves never commit.
    private var activeTokens: [UUID: UInt64] = [:]
    /// Surfaces seen in this run, including restored ones before their first save.
    private var observed: Set<UUID> = []
    /// Saved screens belonging to sessions that have not been verified.
    private var protected: Set<UUID> = []
    /// Archive at most one previous screen per pane in this run.
    private var preservedBeforeWrite: Set<UUID> = []
    var onSaveFailure: ((Error) -> Void)?
    private var reportedFailure = false
    private let writeQueue = DispatchQueue(label: "codes.prod.tako.snapshots.writer", qos: .utility)
    private var timer: Timer?

    nonisolated init(store: SessionSnapshotStore = .shared) {
        self.store = store
    }

    /// A disconnected pane must retain its last saved screen even if it is
    /// closed before the next snapshot timer fires.
    func protect(id: UUID) {
        protected.insert(id)
        activeTokens[id] = (activeTokens[id] ?? 0) + 1
    }

    func start(settings: @escaping @MainActor () -> Settings, surfaces: @escaping @MainActor () -> [Tako.SurfaceView]) {
        timer?.invalidate()
        let initial = surfaces()
        observed = Set(initial.map(\.id))
        protected = Set(initial.filter { $0.hadPersistentSession && !($0.persistence?.confirmedLive ?? false) }.map(\.id))
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.save(surfaces(), settings: settings(), asynchronous: true)
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Writes the tabs that changed since their last save and removes the
    /// files of tabs that are gone. With saving off, or while Secure
    /// Keyboard Entry is on, saved screen snapshots are removed.
    func save(_ surfaces: [Tako.SurfaceView], settings: Settings, now: Date = Date(), asynchronous: Bool = false) {
        for surface in surfaces {
            if let session = surface.persistence, let window = surface.window, WorkspaceStore.shared.persistenceAvailable {
                let tabID = window.stableTabIdentifier
                let privateInput = settings.secureInput || surface.isSecureInput || SecureInput.shared.isSecure(for: surface)
                let windowTabIDs = Tako.CustomTabGroup.existingGroup(for: window)?.windows
                    .filter { !Tako.CustomTabGroup.isClosed($0) }.map(\.stableTabIdentifier)
                session.rememberPlacement(workspaceID: WorkspaceStore.shared.workspace(forTab: tabID)?.id,
                    tabIdentifier: tabID, workingDirectory: privateInput ? nil : surface.pwd, windowTabIdentifiers: windowTabIDs)
            }
        }
        guard settings.enabled, !settings.secureInput else {
            store.removeAll()
            written = [:]
            activeTokens = [:]
            observed = []
            protected = []
            preservedBeforeWrite = []
            return
        }
        let share = surfaces.isEmpty ? 0 : settings.limit / UInt64(surfaces.count)
        var live = Set<UUID>()
        for surface in surfaces {
            // Secure-input sessions are strictly excluded from persisted snapshots (G5)
            if SecureInput.shared.isSecure(for: surface) || surface.isSecureInput {
                store.remove(id: surface.id)
                written[surface.id] = nil
                activeTokens[surface.id] = (activeTokens[surface.id] ?? 0) + 1
                continue
            }
            live.insert(surface.id)
            // A recovery placeholder is not the old session's screen. Never
            // replace its last saved screen until the live session is verified.
            if surface.hadPersistentSession && !(surface.persistence?.confirmedLive ?? false) {
                protected.insert(surface.id)
                written[surface.id] = nil
                activeTokens[surface.id] = (activeTokens[surface.id] ?? 0) + 1
                continue
            }
            protected.remove(surface.id)
            // Zero means "no limit" to the engine, never what no room means here.
            // The checkpoint gets what is left after the file's header.
            let budget = share > SessionSnapshotStore.headerSize ? share - SessionSnapshotStore.headerSize : 0
            guard budget > 0 else {
                store.remove(id: surface.id)
                written[surface.id] = nil
                activeTokens[surface.id] = (activeTokens[surface.id] ?? 0) + 1
                continue
            }
            // A file written under a bigger share (fewer tabs, a higher limit)
            // must not stay over the current one; dropping it also forgets
            // that it was written, so it is exported again once it fits.
            if let size = store.size(id: surface.id), size > share {
                store.remove(id: surface.id)
                written[surface.id] = nil
                activeTokens[surface.id] = (activeTokens[surface.id] ?? 0) + 1
            }
            switch surface.exportSnapshotState(maxBytes: budget, unlessGeneration: written[surface.id]) {
            case .unchanged:
                continue
            case .tooLarge:
                // A tab that outgrew its share must not come back showing an
                // older screen than the one it had.
                store.remove(id: surface.id)
                written[surface.id] = nil
                activeTokens[surface.id] = (activeTokens[surface.id] ?? 0) + 1
            case .exported(let checkpoint, let generation):
                let surfaceId = surface.id
                let token = (activeTokens[surfaceId] ?? 0) + 1
                activeTokens[surfaceId] = token
                if asynchronous {
                    let currentStore = self.store
                    writeQueue.async { [weak self] in
                        let sanitizedCheckpoint = SessionSnapshotRedactor.shared.redact(checkpoint: checkpoint)
                        Task { @MainActor [weak self] in
                            guard let self = self else { return }
                            // Only commit if the captured token is still current (not superseded or invalidated)
                            guard self.activeTokens[surfaceId] == token else { return }
                            if let s = surfaces.first(where: { $0.id == surfaceId }) {
                                if SecureInput.shared.isSecure(for: s) || s.isSecureInput {
                                    self.store.remove(id: surfaceId)
                                    self.written[surfaceId] = nil
                                    return
                                }
                                if s.hadPersistentSession && !(s.persistence?.confirmedLive ?? false) { return }
                            }
                            do {
                                try self.preservePreviousIfNeeded(id: surfaceId)
                                try currentStore.write(SessionSnapshot(savedAt: now, checkpoint: sanitizedCheckpoint), id: surfaceId)
                                self.written[surfaceId] = generation
                            } catch {
                                self.written[surfaceId] = nil
                                self.reportSaveFailure(error)
                            }
                        }
                    }
                } else {
                    do {
                        let sanitizedCheckpoint = SessionSnapshotRedactor.shared.redact(checkpoint: checkpoint)
                        try preservePreviousIfNeeded(id: surfaceId)
                        try store.write(SessionSnapshot(savedAt: now, checkpoint: sanitizedCheckpoint), id: surfaceId)
                        written[surfaceId] = generation
                    } catch {
                        written[surfaceId] = nil
                        reportSaveFailure(error)
                    }
                }
            }
        }
        // Only retire files for surfaces this saver actually tracked. A file
        // absent from a partial restore may be the only copy of a session.
        let retired = observed.union(written.keys).union(activeTokens.keys).subtracting(live).subtracting(protected)
        for id in retired { store.remove(id: id); preservedBeforeWrite.remove(id) }
        observed = live
        written = written.filter { live.contains($0.key) }
        activeTokens = activeTokens.filter { live.contains($0.key) }
    }

    private func preservePreviousIfNeeded(id: UUID) throws {
        guard !preservedBeforeWrite.contains(id) else { return }
        try store.preservePrevious(id: id)
        preservedBeforeWrite.insert(id)
    }

    private func reportSaveFailure(_ error: Error) {
        guard !reportedFailure else { return }
        reportedFailure = true
        onSaveFailure?(error)
    }
}
