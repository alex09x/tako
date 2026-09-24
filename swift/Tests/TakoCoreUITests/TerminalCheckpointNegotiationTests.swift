import Foundation
import XCTest
@testable import TakoCoreUI

/// The typed checkpoint surface a host negotiates against: an explicit
/// version, a typed error that separates "I cannot read this version" from
/// "this payload is damaged", a bounded export, and inspection before
/// committing to an import.
final class TerminalCheckpointNegotiationTests: XCTestCase {
    /// Re-stamp the CRC so a forged container is indistinguishable from an
    /// honest one to every check but the one under test.
    private func reseal(_ blob: Data) -> Data {
        var out = blob
        let payload = [UInt8](out[20...])
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in payload {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
            }
        }
        crc = ~crc
        out.replaceSubrange(16..<20, with: withUnsafeBytes(of: crc.littleEndian) { Data($0) })
        return out
    }

    func testCheckpointVersionIsNegotiatedExplicitly() throws {
        let core = TakoCore(cols: 40, rows: 10)
        XCTAssertEqual(core.checkpointVersion(), 3)
        // v1 and v2 remain readable; v3 is what this build writes.
        XCTAssertTrue(core.checkpointSupports(version: 1))
        XCTAssertTrue(core.checkpointSupports(version: 2))
        XCTAssertTrue(core.checkpointSupports(version: 3))
        XCTAssertFalse(core.checkpointSupports(version: 0))
        XCTAssertFalse(core.checkpointSupports(version: 4))
        XCTAssertFalse(core.checkpointSupports(version: UInt32.max))
    }

    func testHigherVersionContainerFailsAsUnsupportedNotCorrupt() throws {
        let core = TakoCore(cols: 40, rows: 10)
        core.feed(bytes: Data("negotiate".utf8))
        let blob = try core.checkpointExport(flags: 0, maxBytes: 1 << 20)

        var newer = blob
        newer.replaceSubrange(4..<8, with: withUnsafeBytes(of: UInt32(4).littleEndian) { Data($0) })
        let forged = reseal(newer)

        let dest = TakoCore(cols: 20, rows: 6)
        XCTAssertThrowsError(try dest.checkpointImport(blob: forged)) { error in
            guard case TakoCheckpointError.UnsupportedVersion(let version) = error else {
                return XCTFail("expected UnsupportedVersion, got \(error)")
            }
            XCTAssertEqual(version, 4)
        }
        XCTAssertThrowsError(try dest.checkpointInspect(blob: forged)) { error in
            guard case TakoCheckpointError.UnsupportedVersion = error else {
                return XCTFail("expected UnsupportedVersion, got \(error)")
            }
        }

        // Damage is still reported as damage, so the two decisions stay apart.
        var corrupt = blob
        corrupt[corrupt.count - 1] ^= 0xFF
        XCTAssertThrowsError(try dest.checkpointImport(blob: corrupt)) { error in
            guard case TakoCheckpointError.Corrupt = error else {
                return XCTFail("expected Corrupt, got \(error)")
            }
        }
    }

    func testCheckpointInspectReportsWhatTheContainerDeclares() throws {
        let core = TakoCore(cols: 37, rows: 11)
        core.feed(bytes: Data("inspect me".utf8))
        let blob = try core.checkpointExport(flags: 0, maxBytes: 1 << 20)

        let info = try core.checkpointInspect(blob: blob)
        // What inspect reports is what this build wrote, not a literal that
        // drifts the next time the container version moves.
        XCTAssertEqual(info.version, core.checkpointVersion())
        XCTAssertEqual(info.version, 3)
        XCTAssertEqual(info.cols, 37)
        XCTAssertEqual(info.rows, 11)
        XCTAssertEqual(Int(info.payloadLen), blob.count - 20)
        XCTAssertEqual(info.flags, 0)

        XCTAssertThrowsError(try core.checkpointInspect(blob: Data())) { error in
            guard case TakoCheckpointError.NullArgument = error else {
                return XCTFail("expected NullArgument, got \(error)")
            }
        }
    }

    func testBoundedExportRefusesAtTheCallerSuppliedCap() throws {
        let core = TakoCore(cols: 80, rows: 24)
        core.feed(bytes: Data("bounded export".utf8))
        let full = try core.checkpointExport(flags: 0, maxBytes: 64 * 1024 * 1024)

        XCTAssertThrowsError(try core.checkpointExport(flags: 0, maxBytes: 64)) { error in
            guard case TakoCheckpointError.TooLarge(let size, let limit) = error else {
                return XCTFail("expected TooLarge, got \(error)")
            }
            XCTAssertEqual(limit, 64)
            XCTAssertGreaterThan(size, 64, "the reported size is the real one")
        }

        // Refusing allocated nothing and changed nothing.
        let again = try core.checkpointExport(flags: 0, maxBytes: 64 * 1024 * 1024)
        XCTAssertEqual(again, full, "a refused export leaves the terminal untouched")
        XCTAssertTrue(core.verifyCheckpoint(bytes: again))
    }

    /// A rejected import leaves the destination byte-identical, proven by
    /// comparing exports rather than by looking at the screen.
    func testRejectedImportLeavesTheDestinationByteIdentical() throws {
        let dest = TakoCore(cols: 60, rows: 20)
        dest.feed(bytes: Data("\u{001B}[31mred\u{001B}[m normal\r\nsecond\u{001B}]0;title\u{0007}".utf8))
        let before = try dest.checkpointExport(flags: 0, maxBytes: 1 << 20)
        let epochBefore = dest.stateEpoch()

        let source = TakoCore(cols: 30, rows: 8)
        source.feed(bytes: Data("SOURCE".utf8))
        let good = try source.checkpointExport(flags: 0, maxBytes: 1 << 20)

        var truncated = good
        truncated.removeLast(good.count / 2)
        var badMagic = good
        badMagic.replaceSubrange(0..<4, with: Data("BAD!".utf8))
        var badCrc = good
        badCrc[badCrc.count - 1] ^= 0xFF

        for (index, blob) in [Data(), Data([1, 2, 3]), truncated, badMagic, badCrc].enumerated() {
            XCTAssertThrowsError(try dest.checkpointImport(blob: blob), "blob \(index)")
            XCTAssertEqual(
                try dest.checkpointExport(flags: 0, maxBytes: 1 << 20),
                before,
                "blob \(index): fail-intact, byte for byte"
            )
            XCTAssertEqual(dest.stateEpoch(), epochBefore, "blob \(index): no epoch published")
        }

        try dest.checkpointImport(blob: good)
        XCTAssertGreaterThan(dest.stateEpoch(), epochBefore)
        XCTAssertEqual(try dest.checkpointExport(flags: 0, maxBytes: 1 << 20), good)
    }

    /// The cap a host negotiates is the cap on what it will have to carry.
    /// The 20-byte container header is part of that, so a cap that excluded it
    /// would hand a 64 MiB channel 64 MiB + 20. And `maxBytes: 0` means "no
    /// caller limit" -- the library ceiling -- not a limit of zero.
    func testTheNegotiatedCapCoversTheWholeBlob() throws {
        let core = TakoCore(cols: 80, rows: 24)
        core.feed(bytes: Data("the cap covers the header".utf8))

        let ceiling = try core.checkpointExport(flags: 0, maxBytes: 64 * 1024 * 1024)
        let exact = UInt64(ceiling.count)

        // 0 is the ceiling, not an error and not an empty result.
        XCTAssertEqual(
            try core.checkpointExport(flags: 0, maxBytes: 0),
            ceiling,
            "maxBytes 0 means the library ceiling"
        )

        // Exactly enough fits; one byte less refuses and reports the whole
        // size the caller would need, header included.
        let atCap = try core.checkpointExport(flags: 0, maxBytes: exact)
        XCTAssertEqual(atCap, ceiling)
        XCTAssertLessThanOrEqual(UInt64(atCap.count), exact)

        XCTAssertThrowsError(try core.checkpointExport(flags: 0, maxBytes: exact - 1)) { error in
            guard case TakoCheckpointError.TooLarge(let size, let limit) = error else {
                return XCTFail("expected TooLarge, got \(error)")
            }
            XCTAssertEqual(size, exact, "the reported size counts the container header")
            XCTAssertEqual(limit, exact - 1)
        }

        // No cap ever yields a blob larger than itself.
        for cap in (exact - 4)...(exact + 4) {
            if let blob = try? core.checkpointExport(flags: 0, maxBytes: cap) {
                XCTAssertLessThanOrEqual(
                    UInt64(blob.count), cap, "cap \(cap) produced \(blob.count) bytes")
            } else {
                XCTAssertLessThan(cap, exact, "cap \(cap) refused but was large enough")
            }
        }

        // A boundary refusal changed nothing.
        XCTAssertEqual(try core.checkpointExport(flags: 0, maxBytes: 0), ceiling)
        XCTAssertTrue(core.verifyCheckpoint(bytes: ceiling))
    }

    /// A checkpoint taken mid a large in-flight OSC imports back. Export and
    /// import agree on the limits, so an honest checkpoint is never one this
    /// build refuses to read.
    func testLargeInFlightOscCheckpointRoundTripsThroughTheFfi() throws {
        let core = TakoCore(cols: 80, rows: 24)
        var seq = Data("\u{001B}]1337;File=inline=1;".utf8)
        seq.append(Data(repeating: UInt8(ascii: "A"), count: 2 * 1024 * 1024))
        core.feed(bytes: seq)

        let blob = try core.checkpointExport(flags: 0, maxBytes: 64 * 1024 * 1024)
        XCTAssertTrue(core.verifyCheckpoint(bytes: blob))

        let dest = TakoCore(cols: 20, rows: 6)
        try dest.checkpointImport(blob: blob)
        dest.feed(bytes: Data("MARKER\u{0007}".utf8))
        XCTAssertFalse(
            dest.getPlainText(startRow: 0, maxRows: 24).contains("MARKER"),
            "the OSC continued across the checkpoint instead of being printed"
        )
    }
}
