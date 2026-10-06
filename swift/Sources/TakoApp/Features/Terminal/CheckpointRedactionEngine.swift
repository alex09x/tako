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

struct CheckpointRedactionEngine {
    let input: Data
    let version: UInt32
    let regexes: [NSRegularExpression]
    var offset: Int = 0
    var out = Data()

    mutating func redactPayload() -> Data? {
        // 1. Dimensions and leading geometry
        guard let cols = readUInt32(), let rows = readUInt32() else { return nil }
        var colsLE = cols.littleEndian
        withUnsafeBytes(of: &colsLE) { out.append(contentsOf: $0) }
        var rowsLE = rows.littleEndian
        withUnsafeBytes(of: &rowsLE) { out.append(contentsOf: $0) }

        guard copyUInt8() else { return nil } // active buffer
        guard copyUInt32() else { return nil } // scroll_top
        guard copyUInt32() else { return nil } // scroll_bottom
        guard copyUInt32() else { return nil } // scroll_left
        guard copyUInt32() else { return nil } // scroll_right
        guard copyUInt32() else { return nil } // viewport_offset
        guard copyBool() else { return nil }   // pending_wrap

        // 2. Primary Grid
        guard copyUInt32() else { return nil } // prim_cap
        guard copyUInt64() else { return nil } // prim_evicted
        guard let primSbLen = readUInt32() else { return nil }
        var primSbLenLE = primSbLen.littleEndian
        withUnsafeBytes(of: &primSbLenLE) { out.append(contentsOf: $0) }

        for _ in 0..<primSbLen {
            guard copyBool() else { return nil } // wrapped
            if version >= 5 {
                guard copyUInt8() else { return nil } // semantic
            }
            guard let cellsLen = readUInt32() else { return nil }
            var cellsLenLE = cellsLen.littleEndian
            withUnsafeBytes(of: &cellsLenLE) { out.append(contentsOf: $0) }
            guard var cells = readCells(expectedLen: Int(cellsLen)) else { return nil }
            redactRow(&cells)
            writeCells(cells, into: &out)
        }

        for _ in 0..<rows {
            guard copyBool() else { return nil } // wrapped
            guard copyUInt8() else { return nil } // semantic
            guard var cells = readCells(expectedLen: Int(cols)) else { return nil }
            redactRow(&cells)
            writeCells(cells, into: &out)
        }

        // 3. Alternate Grid
        guard copyUInt32() else { return nil } // alt_cap
        guard copyUInt64() else { return nil } // alt_evicted
        guard let altSbLen = readUInt32() else { return nil }
        var altSbLenLE = altSbLen.littleEndian
        withUnsafeBytes(of: &altSbLenLE) { out.append(contentsOf: $0) }

        for _ in 0..<altSbLen {
            guard copyBool() else { return nil } // wrapped
            if version >= 5 {
                guard copyUInt8() else { return nil } // semantic
            }
            guard let cellsLen = readUInt32() else { return nil }
            var cellsLenLE = cellsLen.littleEndian
            withUnsafeBytes(of: &cellsLenLE) { out.append(contentsOf: $0) }
            guard var cells = readCells(expectedLen: Int(cellsLen)) else { return nil }
            redactRow(&cells)
            writeCells(cells, into: &out)
        }

        for _ in 0..<rows {
            guard copyBool() else { return nil } // wrapped
            guard copyUInt8() else { return nil } // semantic
            guard var cells = readCells(expectedLen: Int(cols)) else { return nil }
            redactRow(&cells)
            writeCells(cells, into: &out)
        }

        // 4. Cursor
        guard copyUInt32() else { return nil } // row
        guard copyUInt32() else { return nil } // col
        guard copyColor() else { return nil }  // fg
        guard copyColor() else { return nil }  // bg
        guard copyUInt16() else { return nil } // attrs
        guard copyUInt8() else { return nil }  // underline_style
        guard copyColor() else { return nil }  // underline_color
        guard copyBool() else { return nil }   // cursor_visible
        guard copyUInt8() else { return nil }  // shape
        guard copyBool() else { return nil }   // blinking

        // 5. Saved Cursor
        guard let hasSaved = readBool() else { return nil }
        out.append(hasSaved ? 0x01 : 0x00)
        if hasSaved {
            guard copyUInt32() else { return nil } // s_row
            guard copyUInt32() else { return nil } // s_col
            guard copyColor() else { return nil }  // s_fg
            guard copyColor() else { return nil }  // s_bg
            guard copyUInt16() else { return nil } // s_attrs
            guard copyUInt8() else { return nil }  // s_g0
            guard copyUInt8() else { return nil }  // s_g1
            guard copyBool() else { return nil }   // s_shift_out
            guard copyBool() else { return nil }   // s_origin_mode
            guard copyBool() else { return nil }   // s_pending_wrap
            guard copyUInt8() else { return nil }  // s_prot
            guard copyUInt8() else { return nil }  // s_gr_slot
        }

        // 6. Tab Stops
        guard let tabCols = readUInt32() else { return nil }
        var tabColsLE = tabCols.littleEndian
        withUnsafeBytes(of: &tabColsLE) { out.append(contentsOf: $0) }
        let bitsetLen = (Int(tabCols) + 7) / 8
        guard copyBytes(bitsetLen) else { return nil }

        // 7. Modes
        guard copyUInt32() else { return nil } // mode_flags
        guard copyUInt8() else { return nil }  // mouse_tracking

        // 8. Parser State
        guard copyUInt8() else { return nil }  // state
        guard let interLen = readUInt8() else { return nil }
        out.append(interLen)
        guard copyBytes(Int(interLen)) else { return nil }
        guard let paramsLen = readUInt8() else { return nil }
        out.append(paramsLen)
        guard copyBytes(Int(paramsLen) * 2) else { return nil }
        guard copyUInt32() else { return nil } // params_sep
        guard copyBool() else { return nil }   // ignore
        guard copyLengthPrefixedBytes() else { return nil } // osc_raw
        guard copyLengthPrefixedBytes() else { return nil } // apc_raw
        guard copyUInt8() else { return nil }  // utf8_need
        guard copyUInt32() else { return nil } // utf8_cp

        // 9. DCS
        guard copyUInt8() else { return nil } // dcs_kind
        guard copyLengthPrefixedBytes() else { return nil } // dcs_buf

        // 10. Charsets & Shift
        guard copyUInt8() else { return nil } // g0
        guard copyUInt8() else { return nil } // g1
        guard copyUInt8() else { return nil } // g2
        guard copyUInt8() else { return nil } // g3
        guard copyBool() else { return nil }  // shift_out
        guard copyUInt8() else { return nil } // gr_slot
        guard let hasSingleShift = readBool() else { return nil }
        out.append(hasSingleShift ? 0x01 : 0x00)
        if hasSingleShift {
            guard copyUInt8() else { return nil }
        }

        // 11. Hyperlinks
        guard let hCount = readUInt32() else { return nil }
        var hCountLE = hCount.littleEndian
        withUnsafeBytes(of: &hCountLE) { out.append(contentsOf: $0) }
        for _ in 0..<hCount {
            guard redactLengthPrefixedString() else { return nil }
        }
        guard let hIdCount = readUInt32() else { return nil }
        var hIdCountLE = hIdCount.littleEndian
        withUnsafeBytes(of: &hIdCountLE) { out.append(contentsOf: $0) }
        for _ in 0..<hIdCount {
            guard redactLengthPrefixedString() else { return nil } // URL key
            guard copyUInt32() else { return nil }                 // ID value
        }
        guard let hasCurHlink = readBool() else { return nil }
        out.append(hasCurHlink ? 0x01 : 0x00)
        if hasCurHlink {
            guard copyUInt32() else { return nil }
        }

        // 12. Title & Title Stack
        guard redactLengthPrefixedString() else { return nil } // title
        guard let tsCount = readUInt32() else { return nil }
        var tsCountLE = tsCount.littleEndian
        withUnsafeBytes(of: &tsCountLE) { out.append(contentsOf: $0) }
        for _ in 0..<tsCount {
            guard redactLengthPrefixedString() else { return nil }
        }

        // 13. Palette
        guard copyBytes(768) else { return nil } // 256 * 3 colors
        guard let hasDefFg = readBool() else { return nil }
        out.append(hasDefFg ? 0x01 : 0x00)
        if hasDefFg { guard copyBytes(3) else { return nil } }
        guard let hasDefBg = readBool() else { return nil }
        out.append(hasDefBg ? 0x01 : 0x00)
        if hasDefBg { guard copyBytes(3) else { return nil } }
        guard let hasCurCol = readBool() else { return nil }
        out.append(hasCurCol ? 0x01 : 0x00)
        if hasCurCol { guard copyBytes(3) else { return nil } }

        // 14. Kitty Keyboard
        guard let kkCount = readUInt8() else { return nil }
        out.append(kkCount)
        guard copyBytes(Int(kkCount)) else { return nil }

        // 15. Graphics Placements
        guard let pCount = readUInt32() else { return nil }
        var pCountLE = pCount.littleEndian
        withUnsafeBytes(of: &pCountLE) { out.append(contentsOf: $0) }
        guard copyBytes(Int(pCount) * 16) else { return nil } // image_id, placement_id, row, col

        // 16. Graphics Images & Pending Transfers
        guard copyUInt32() else { return nil } // next_image_id
        guard copyUInt64() else { return nil } // next_image_generation
        guard let imagesCount = readUInt32() else { return nil }
        var imgCountLE = imagesCount.littleEndian
        withUnsafeBytes(of: &imgCountLE) { out.append(contentsOf: $0) }
        for _ in 0..<imagesCount {
            guard copyUInt32() else { return nil } // id
            guard copyUInt8() else { return nil }  // format
            guard copyUInt32() else { return nil } // width
            guard copyUInt32() else { return nil } // height
            guard copyUInt64() else { return nil } // generation
            guard copyLengthPrefixedBytes() else { return nil } // pixels
        }

        guard let pendingCount = readUInt32() else { return nil }
        var penCountLE = pendingCount.littleEndian
        withUnsafeBytes(of: &penCountLE) { out.append(contentsOf: $0) }
        for _ in 0..<pendingCount {
            guard let keyTag = readUInt8() else { return nil }
            out.append(keyTag)
            if keyTag == 1 {
                guard copyUInt32() else { return nil } // image id
            }
            guard copyUInt8() else { return nil } // format
            guard copyUInt32() else { return nil } // width
            guard copyUInt32() else { return nil } // height
            guard copyLengthPrefixedBytes() else { return nil } // data
        }

        // 17. Remaining State
        guard let hasLastPrinted = readBool() else { return nil }
        out.append(hasLastPrinted ? 0x01 : 0x00)
        if hasLastPrinted { guard copyUInt32() else { return nil } }
        guard copyUInt8() else { return nil }  // protected_mode
        guard redactLengthPrefixedString() else { return nil } // answerback
        guard redactLengthPrefixedString() else { return nil } // xtversion
        guard copyUInt32() else { return nil } // width_px
        guard copyUInt32() else { return nil } // height_px
        guard copyUInt8() else { return nil }  // dark_scheme
        guard copyUInt8() else { return nil }  // semantic_content
        guard copyUInt16() else { return nil } // checksum_ext

        // 18. Version 1 selection
        if version == 1 {
            guard let hasSel = readBool() else { return nil }
            out.append(hasSel ? 0x01 : 0x00)
            if hasSel { guard copyBytes(17) else { return nil } }
        }

        // 19. Version >= 3 Host Config & Clusters
        if version >= 3 {
            // Host config
            guard copyBytes(768) else { return nil } // base colors (256 * 3)
            guard copyBytes(32) else { return nil }  // overridden bitmask (32 bytes)
            for _ in 0..<3 { // base_fg, base_bg, base_cursor
                guard let hasBase = readBool() else { return nil }
                out.append(hasBase ? 0x01 : 0x00)
                if hasBase { guard copyBytes(3) else { return nil } }
            }
            guard copyBool() else { return nil } // fg_overridden
            guard copyBool() else { return nil } // bg_overridden
            guard copyBool() else { return nil } // cursor_overridden
            guard copyUInt8() else { return nil } // default_cursor_style shape
            guard copyBool() else { return nil }  // default_cursor_style blinking
            guard copyBool() else { return nil }  // cursor_style_overridden

            // Clusters (Primary)
            guard let primClustersCount = readUInt32() else { return nil }
            var pcCountLE = primClustersCount.littleEndian
            withUnsafeBytes(of: &pcCountLE) { out.append(contentsOf: $0) }
            for _ in 0..<primClustersCount {
                guard copyUInt32() else { return nil } // line
                guard copyUInt32() else { return nil } // col
                guard redactLengthPrefixedString() else { return nil } // extra
                guard copyBool() else { return nil }   // wide
            }

            // Clusters (Alternate)
            guard let altClustersCount = readUInt32() else { return nil }
            var acCountLE = altClustersCount.littleEndian
            withUnsafeBytes(of: &acCountLE) { out.append(contentsOf: $0) }
            for _ in 0..<altClustersCount {
                guard copyUInt32() else { return nil } // line
                guard copyUInt32() else { return nil } // col
                guard redactLengthPrefixedString() else { return nil } // extra
                guard copyBool() else { return nil }   // wide
            }

            // Version >= 4 Commands
            if version >= 4 {
                guard let runCount = readUInt32() else { return nil }
                var rcLE = runCount.littleEndian
                withUnsafeBytes(of: &rcLE) { out.append(contentsOf: $0) }
                guard copyBytes(Int(runCount) * 13) else { return nil } // tag(1) + id(8) + n(4) = 13 bytes

                guard copyOptionalUInt64() else { return nil } // pen
                guard copyOptionalUInt64() else { return nil } // next_id
                guard copyOptionalUInt64() else { return nil } // running

                guard let recCount = readUInt32() else { return nil }
                var recCountLE = recCount.littleEndian
                withUnsafeBytes(of: &recCountLE) { out.append(contentsOf: $0) }
                for _ in 0..<recCount {
                    guard copyUInt64() else { return nil } // id
                    guard copyUInt8() else { return nil }  // status
                    guard copyUInt32() else { return nil } // code
                    guard redactOptionalString() else { return nil } // cwd
                    guard redactOptionalString() else { return nil } // input!
                    guard copyBool() else { return nil }   // input_truncated
                    guard copyOptionalUInt64() else { return nil } // started_at_ms
                    if version >= 6 {
                        guard copyOptionalUInt64() else { return nil } // prompt_line
                    }
                }

                guard redactOptionalString() else { return nil } // last_cwd
                guard copyOptionalUInt64() else { return nil }   // input_start line
                guard copyUInt32() else { return nil }           // input_start col
                if version >= 6 {
                    guard copyOptionalUInt64() else { return nil } // last_prompt_line
                }
            }
        }

        // Must consume entire payload
        guard offset == input.count else { return nil }
        return out
    }
}
