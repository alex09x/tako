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

extension CheckpointRedactionEngine {
    mutating func readUInt8() -> UInt8? {
        guard offset < input.count else { return nil }
        let v = input[offset]
        offset += 1
        return v
    }

    mutating func readUInt16() -> UInt16? {
        guard offset + 2 <= input.count else { return nil }
        let v = input.subdata(in: offset..<offset+2).withUnsafeBytes { $0.load(as: UInt16.self) }
        offset += 2
        return UInt16(littleEndian: v)
    }

    mutating func readUInt32() -> UInt32? {
        guard offset + 4 <= input.count else { return nil }
        let v = input.subdata(in: offset..<offset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
        offset += 4
        return UInt32(littleEndian: v)
    }

    mutating func readUInt64() -> UInt64? {
        guard offset + 8 <= input.count else { return nil }
        let v = input.subdata(in: offset..<offset+8).withUnsafeBytes { $0.load(as: UInt64.self) }
        offset += 8
        return UInt64(littleEndian: v)
    }

    mutating func readBool() -> Bool? {
        guard let b = readUInt8() else { return nil }
        return b != 0
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard offset + count <= input.count else { return nil }
        let d = input.subdata(in: offset..<offset+count)
        offset += count
        return d
    }

    mutating func copyBytes(_ count: Int) -> Bool {
        guard let d = readBytes(count) else { return false }
        out.append(d)
        return true
    }

    mutating func copyUInt8() -> Bool {
        guard let v = readUInt8() else { return false }
        out.append(v)
        return true
    }

    mutating func copyUInt32() -> Bool {
        guard let d = readBytes(4) else { return false }
        out.append(d)
        return true
    }

    mutating func copyUInt64() -> Bool {
        guard let d = readBytes(8) else { return false }
        out.append(d)
        return true
    }

    mutating func copyBool() -> Bool {
        copyUInt8()
    }

    mutating func readColor() -> (tag: UInt8, bytes: Data)? {
        guard let tag = readUInt8() else { return nil }
        switch tag {
        case 0:
            return (0, Data([0]))
        case 1:
            guard let n = readUInt8() else { return nil }
            return (1, Data([1, n]))
        case 2:
            guard let rgb = readBytes(3) else { return nil }
            var d = Data([2])
            d.append(rgb)
            return (2, d)
        default:
            return nil
        }
    }

    mutating func copyUInt16() -> Bool {
        guard let d = readBytes(2) else { return false }
        out.append(d)
        return true
    }

    mutating func copyColor() -> Bool {
        guard let c = readColor() else { return false }
        out.append(c.bytes)
        return true
    }

    mutating func copyLengthPrefixedBytes() -> Bool {
        guard let len = readUInt32() else { return false }
        var lenLE = len.littleEndian
        withUnsafeBytes(of: &lenLE) { out.append(contentsOf: $0) }
        return copyBytes(Int(len))
    }

    mutating func redactLengthPrefixedString() -> Bool {
        guard let len = readUInt32() else { return false }
        let l = Int(len)
        guard let strBytes = readBytes(l) else { return false }
        let str = String(data: strBytes, encoding: .utf8) ?? ""
        let redacted = redactText(str)
        let utf8Bytes = Data(redacted.utf8)
        var newLen = UInt32(utf8Bytes.count).littleEndian
        withUnsafeBytes(of: &newLen) { out.append(contentsOf: $0) }
        out.append(utf8Bytes)
        return true
    }

    mutating func redactOptionalString() -> Bool {
        guard let present = readBool() else { return false }
        out.append(present ? 0x01 : 0x00)
        if present {
            return redactLengthPrefixedString()
        }
        return true
    }

    mutating func copyOptionalUInt64() -> Bool {
        guard let present = readBool() else { return false }
        out.append(present ? 0x01 : 0x00)
        return copyUInt64()
    }

    func redactText(_ str: String) -> String {
        guard !regexes.isEmpty, !str.isEmpty else { return str }
        var modified = str
        for regex in regexes {
            let range = NSRange(modified.startIndex..<modified.endIndex, in: modified)
            modified = regex.stringByReplacingMatches(
                in: modified,
                options: [],
                range: range,
                withTemplate: "[REDACTED]"
            )
        }
        return modified
    }
}
