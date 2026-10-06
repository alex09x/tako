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

struct DecodedCell {
    var char: UInt32
    var content: Data
    var isDefault: Bool
}

extension CheckpointRedactionEngine {
    mutating func readSingleCell() -> DecodedCell? {
        guard let cp = readUInt32() else { return nil }
        var content = Data()
        guard let fg = readColor() else { return nil }
        content.append(fg.bytes)
        guard let bg = readColor() else { return nil }
        content.append(bg.bytes)
        guard let attrs = readBytes(2) else { return nil }
        content.append(attrs)
        guard let flags = readUInt8() else { return nil }
        content.append(flags)
        guard let uStyle = readUInt8() else { return nil }
        content.append(uStyle)
        if (flags & (1 << 3)) != 0 {
            guard let uColor = readColor() else { return nil }
            content.append(uColor.bytes)
        }
        if (flags & (1 << 4)) != 0 {
            guard let hLink = readBytes(4) else { return nil }
            content.append(hLink)
        }
        return DecodedCell(char: cp, content: content, isDefault: false)
    }

    mutating func readCells(expectedLen: Int) -> [DecodedCell]? {
        var cells: [DecodedCell] = []
        cells.reserveCapacity(expectedLen)
        while cells.count < expectedLen {
            guard let op = readUInt8() else { return nil }
            switch op {
            case 0x00:
                cells.append(DecodedCell(char: 32, content: Data([0, 0, 0, 0, 0, 0]), isDefault: true))
            case 0x01:
                guard let count = readUInt16() else { return nil }
                let c = Int(count)
                guard c > 0, cells.count + c <= expectedLen else { return nil }
                for _ in 0..<c {
                    cells.append(DecodedCell(char: 32, content: Data([0, 0, 0, 0, 0, 0]), isDefault: true))
                }
            case 0x02:
                guard let cell = readSingleCell() else { return nil }
                cells.append(cell)
            case 0x03:
                guard let count = readUInt16() else { return nil }
                let c = Int(count)
                guard c > 0, cells.count + c <= expectedLen else { return nil }
                guard let cell = readSingleCell() else { return nil }
                for _ in 0..<c {
                    cells.append(cell)
                }
            default:
                return nil
            }
        }
        guard cells.count == expectedLen else { return nil }
        return cells
    }

    func writeCells(_ cells: [DecodedCell], into buffer: inout Data) {
        var idx = 0
        while idx < cells.count {
            let cell = cells[idx]
            if cell.isDefault {
                let start = idx
                while idx < cells.count && cells[idx].isDefault && (idx - start) < 65535 {
                    idx += 1
                }
                let count = idx - start
                if count == 1 {
                    buffer.append(0x00)
                } else {
                    buffer.append(0x01)
                    var c = UInt16(count).littleEndian
                    withUnsafeBytes(of: &c) { buffer.append(contentsOf: $0) }
                }
            } else {
                let start = idx
                while idx < cells.count && !cells[idx].isDefault && cells[idx].char == cell.char && cells[idx].content == cell.content && (idx - start) < 65535 {
                    idx += 1
                }
                let count = idx - start
                if count == 1 {
                    buffer.append(0x02)
                    var cp = cell.char.littleEndian
                    withUnsafeBytes(of: &cp) { buffer.append(contentsOf: $0) }
                    buffer.append(cell.content)
                } else {
                    buffer.append(0x03)
                    var c = UInt16(count).littleEndian
                    withUnsafeBytes(of: &c) { buffer.append(contentsOf: $0) }
                    var cp = cell.char.littleEndian
                    withUnsafeBytes(of: &cp) { buffer.append(contentsOf: $0) }
                    buffer.append(cell.content)
                }
            }
        }
    }

    func redactRow(_ cells: inout [DecodedCell]) {
        guard !cells.isEmpty else { return }
        let scalars = cells.map { UnicodeScalar($0.char) ?? UnicodeScalar(32)! }
        let line = String(String.UnicodeScalarView(scalars))
        guard !line.isEmpty else { return }

        for regex in regexes {
            let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
            let matches = regex.matches(in: line, options: [], range: nsRange)
            for match in matches {
                guard let strRange = Range(match.range, in: line) else { continue }
                let startIdx = line.distance(from: line.startIndex, to: strRange.lowerBound)
                let endIdx = line.distance(from: line.startIndex, to: strRange.upperBound)
                guard startIdx >= 0, endIdx <= cells.count, startIdx < endIdx else { continue }
                for i in startIdx..<endIdx {
                    cells[i].char = 42 // ASCII '*' (0x2A)
                    if cells[i].isDefault {
                        cells[i].isDefault = false
                        cells[i].content = Data([0, 0, 0, 0, 0, 0])
                    }
                }
            }
        }
    }
}
