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
import XCTest
@testable import Tako
@testable import TakoKit

/// XCTest suite verifying terminal geometry restoration for persistent sessions
/// and saved tab snapshots, preventing cursor desync / 80x24 truncation in Ink/TUI apps.
@MainActor
final class SessionGeometryRestorationTests: XCTestCase {

    private final class TemporaryStore {
        let store: SessionSnapshotStore
        private let previous: SessionSnapshotStore

        init() {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("tako-geom-test-\(UUID().uuidString)", isDirectory: true)
            store = SessionSnapshotStore(directory: dir)
            previous = SessionSnapshotStore.shared
            SessionSnapshotStore.shared = store
        }

        func tearDown() {
            SessionSnapshotStore.shared = previous
            try? FileManager.default.removeItem(at: store.directory)
        }
    }

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        NSApplication.shared.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            TakoTerminalNSView.isMetalDisabledForTesting = true
        }
    }

    // MARK: - Checkpoint Geometry Header Parsing

    func testCheckpointGeometryParsingValidSyntheticHeader() {
        // Construct a synthetic 28-byte checkpoint with standard TKCK magic:
        // Bytes 0..3: "TKCK" (0x54, 0x4b, 0x43, 0x4b)
        // Bytes 4..19: Header flags, version, reserved
        // Bytes 20..23: cols = 169 (little-endian UInt32: 0xa9, 0x00, 0x00, 0x00)
        // Bytes 24..27: rows = 41  (little-endian UInt32: 0x29, 0x00, 0x00, 0x00)
        var data = Data([0x54, 0x4b, 0x43, 0x4b])
        data.append(contentsOf: [UInt8](repeating: 0, count: 16))
        var cols: UInt32 = 169
        var rows: UInt32 = 41
        withUnsafeBytes(of: cols.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: rows.littleEndian) { data.append(contentsOf: $0) }

        let snapshot = SessionSnapshot(savedAt: Date(), checkpoint: data)
        let geom = snapshot.checkpointGeometry
        XCTAssertNotNil(geom)
        XCTAssertEqual(geom?.cols, 169)
        XCTAssertEqual(geom?.rows, 41)

        // Also verify TKCP compatibility
        var legacyData = data
        legacyData[3] = 0x50 // 'P'
        let legacySnapshot = SessionSnapshot(savedAt: Date(), checkpoint: legacyData)
        XCTAssertEqual(legacySnapshot.checkpointGeometry?.cols, 169)
        XCTAssertEqual(legacySnapshot.checkpointGeometry?.rows, 41)
    }

    func testCheckpointGeometryParsingRejectsInvalidOrTruncatedData() {
        // Truncated (< 28 bytes)
        let shortSnapshot = SessionSnapshot(savedAt: Date(), checkpoint: Data([0x54, 0x4b, 0x43, 0x50, 0x01]))
        XCTAssertNil(shortSnapshot.checkpointGeometry)

        // Invalid magic header
        var badMagic = Data([0x58, 0x58, 0x58, 0x58])
        badMagic.append(contentsOf: [UInt8](repeating: 0, count: 24))
        let badMagicSnapshot = SessionSnapshot(savedAt: Date(), checkpoint: badMagic)
        XCTAssertNil(badMagicSnapshot.checkpointGeometry)

        // Zero columns or rows
        var zeroCols = Data([0x54, 0x4b, 0x43, 0x50])
        zeroCols.append(contentsOf: [UInt8](repeating: 0, count: 24))
        let zeroSnapshot = SessionSnapshot(savedAt: Date(), checkpoint: zeroCols)
        XCTAssertNil(zeroSnapshot.checkpointGeometry)

        // Impossibly large dimensions (> 10000)
        var hugeData = Data([0x54, 0x4b, 0x43, 0x50])
        hugeData.append(contentsOf: [UInt8](repeating: 0, count: 16))
        var hugeCols: UInt32 = 20000
        var hugeRows: UInt32 = 20000
        withUnsafeBytes(of: hugeCols.littleEndian) { hugeData.append(contentsOf: $0) }
        withUnsafeBytes(of: hugeRows.littleEndian) { hugeData.append(contentsOf: $0) }
        let hugeSnapshot = SessionSnapshot(savedAt: Date(), checkpoint: hugeData)
        XCTAssertNil(hugeSnapshot.checkpointGeometry)
    }

    func testRealCoreCheckpointExportContainsAccurateGeometry() throws {
        let core = TakoCore(cols: 169, rows: 41)
        core.feed(bytes: Data("Claude Code v1.0.0\r\n❯ prompt line\r\n".utf8))

        let blob = try core.checkpointExport(flags: 0, maxBytes: 1024 * 1024)
        let snapshot = SessionSnapshot(savedAt: Date(), checkpoint: blob)

        let geom = snapshot.checkpointGeometry
        XCTAssertNotNil(geom, "Real checkpointExport blob must have parseable checkpointGeometry")
        XCTAssertEqual(geom?.cols, 169)
        XCTAssertEqual(geom?.rows, 41)
    }

    // MARK: - SurfaceConfiguration & SurfaceView Geometry

    func testSurfaceViewInitWithRestoredSnapshotGeometry() throws {
        let core = TakoCore(cols: 169, rows: 41)
        core.feed(bytes: Data("Claude Code running in zmx session\r\n".utf8))
        let blob = try core.checkpointExport(flags: 0, maxBytes: 1024 * 1024)
        let snapshot = SessionSnapshot(savedAt: Date(), checkpoint: blob)

        var config = Tako.SurfaceConfiguration()
        config.isRestored = true
        config.restoredSnapshot = snapshot

        let surface = Tako.SurfaceView(nil, baseConfig: config)
        defer { surface.close() }

        XCTAssertEqual(surface.cols, 169, "SurfaceView.cols must match restored snapshot geometry")
        XCTAssertEqual(surface.rows, 41, "SurfaceView.rows must match restored snapshot geometry")
        XCTAssertEqual(Int(surface.core.cols()), 169)
        XCTAssertEqual(Int(surface.core.rows()), 41)
    }

    func testSurfaceViewInitWithExplicitInitialColsAndRows() {
        var config = Tako.SurfaceConfiguration()
        config.initialCols = 140
        config.initialRows = 38

        let surface = Tako.SurfaceView(nil, baseConfig: config)
        defer { surface.close() }

        XCTAssertEqual(surface.cols, 140)
        XCTAssertEqual(surface.rows, 38)
        XCTAssertEqual(Int(surface.core.cols()), 140)
        XCTAssertEqual(Int(surface.core.rows()), 38)
    }

    func testSurfaceViewInitWithFrameSetsInitialSize() {
        let rect = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let surface = Tako.SurfaceView(frame: rect)
        defer { surface.close() }

        XCTAssertEqual(surface.frame, rect)
        XCTAssertEqual(surface.initialSize, rect.size)
    }

    func testShowSnapshotUpdatesExistingSurfaceDimensions() throws {
        // Start surface with default 80x24
        let surface = Tako.SurfaceView(frame: .zero)
        defer { surface.close() }
        XCTAssertEqual(surface.cols, 80)
        XCTAssertEqual(surface.rows, 24)

        // Build a snapshot with 169x41
        let core = TakoCore(cols: 169, rows: 41)
        core.feed(bytes: Data("Target screen content\r\n".utf8))
        let blob = try core.checkpointExport(flags: 0, maxBytes: 1024 * 1024)
        let snapshot = SessionSnapshot(savedAt: Date(), checkpoint: blob)

        surface.showSnapshot(snapshot)

        XCTAssertEqual(surface.cols, 169, "showSnapshot must update surface.cols from checkpointGeometry")
        XCTAssertEqual(surface.rows, 41, "showSnapshot must update surface.rows from checkpointGeometry")
    }

    // MARK: - Snapshot Store & Codable Restoration Roundtrip

    func testCodableRestorationRoundtripPreservesGeometry() throws {
        let tmp = TemporaryStore()
        defer { tmp.tearDown() }

        // Create an original surface with non-default geometry
        var initialConfig = Tako.SurfaceConfiguration()
        initialConfig.initialCols = 169
        initialConfig.initialRows = 41
        let original = Tako.SurfaceView(nil, baseConfig: initialConfig)
        defer { original.close() }

        XCTAssertEqual(original.cols, 169)
        XCTAssertEqual(original.rows, 41)
        original.core.feed(bytes: Data("Claude Code in persistent session\r\n❯ status\r\n".utf8))

        // Save snapshot to the temporary store
        let saver = SessionSnapshotSaver(store: tmp.store)
        let settings = SessionSnapshotSaver.Settings(enabled: true, limit: 64 << 20, secureInput: false)
        saver.save([original], settings: settings)

        // Verify the snapshot exists on disk and has correct geometry
        let savedSnapshot = tmp.store.read(id: original.id)
        XCTAssertNotNil(savedSnapshot)
        XCTAssertEqual(savedSnapshot?.checkpointGeometry?.cols, 169)
        XCTAssertEqual(savedSnapshot?.checkpointGeometry?.rows, 41)

        // Encode and decode the SurfaceView
        let encoded = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Tako.SurfaceView.self, from: encoded)
        defer { restored.close() }

        XCTAssertEqual(restored.id, original.id)
        XCTAssertEqual(restored.cols, 169, "Restored SurfaceView must not collapse to 80 cols")
        XCTAssertEqual(restored.rows, 41, "Restored SurfaceView must not collapse to 24 rows")
        XCTAssertEqual(Int(restored.core.cols()), 169)
        XCTAssertEqual(Int(restored.core.rows()), 41)

        let bufferText = restored.core.bufferText()
        XCTAssertTrue(bufferText.contains("Claude Code in persistent session"))
    }
}
