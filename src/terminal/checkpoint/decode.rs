/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::api::validate_container;
use super::commands::{CommandState, read_commands};
use super::decode_input::{read_cursor, read_kitty_keyboard, read_modes, read_tabstops};
use super::decode_state::{
    read_graphics, read_hyperlinks, read_palette, read_parser_and_charsets, read_title_and_stack,
};
use super::grid::{read_clusters, read_grid};
use super::host::read_host_config;
use super::reader::Reader;
use super::types::{
    CheckpointError, FieldOffsets, HEADER_SIZE, MAX_DIM, MAX_IMPORT_ALLOC_BYTES,
    MIN_SUPPORTED_VERSION,
};
use crate::terminal::commands::CommandLog;
use crate::terminal::{
    ClipboardPolicy, CursorStyle, GraphemeWidthMethod, ProtectedMode, ResponseQueue, ScreenBuffer,
    SemanticContent, Terminal,
};
use std::collections::{HashMap, VecDeque};

pub fn import(data: &[u8]) -> Result<Terminal, CheckpointError> {
    import_reserving(data, 0)
}

pub fn import_reserving(data: &[u8], reserved: u64) -> Result<Terminal, CheckpointError> {
    import_traced_reserving(data, reserved).map(|(term, _)| term)
}

#[doc(hidden)]
pub fn import_traced(data: &[u8]) -> Result<(Terminal, FieldOffsets), CheckpointError> {
    import_traced_reserving(data, 0)
}

#[doc(hidden)]
pub fn import_traced_reserving(
    data: &[u8],
    reserved: u64,
) -> Result<(Terminal, FieldOffsets), CheckpointError> {
    if reserved > MAX_IMPORT_ALLOC_BYTES {
        return Err(CheckpointError::AllocationLimitExceeded);
    }
    let (version, payload) = validate_container(data)?;
    let mut offsets = FieldOffsets::default();

    let mut r = Reader::with_reservation(payload, reserved);

    let cols = r.read_u32()? as usize;
    let rows = r.read_u32()? as usize;
    if cols == 0 || cols > MAX_DIM || rows == 0 || rows > MAX_DIM {
        return Err(CheckpointError::DimensionOutOfBounds { cols, rows });
    }

    let active_screen = match r.read_u8()? {
        0 => ScreenBuffer::Primary,
        1 => ScreenBuffer::Alternate,
        _ => return Err(CheckpointError::InvalidData("invalid active screen buffer")),
    };
    let scroll_top = r.read_u32()? as usize;
    let scroll_bottom = r.read_u32()? as usize;
    let scroll_left = r.read_u32()? as usize;
    let scroll_right = r.read_u32()? as usize;
    let viewport_offset = r.read_u32()? as usize;
    let pending_wrap = r.read_bool()?;

    let (mut primary, prim_sb_len) = read_grid(&mut r, cols, rows, version)?;
    let (mut alternate, _) = read_grid(&mut r, cols, rows, version)?;

    let (cursor, cursor_visible, cursor_shape, cursor_blinking) = read_cursor(&mut r)?;

    offsets.tab_cols = HEADER_SIZE + r.pos;
    let tabstops = read_tabstops(&mut r, cols, rows)?;
    let modes = read_modes(&mut r)?;
    let (parser, dcs, dcs_buf, g0, g1, g2, g3, shift_out, gr_slot, single_shift) =
        read_parser_and_charsets(&mut r)?;

    let (hyperlinks, hyperlink_ids, current_hyperlink) = read_hyperlinks(&mut r)?;
    let (title, title_stack) = read_title_and_stack(&mut r)?;
    let (mut palette, default_fg, default_bg, cursor_color) = read_palette(&mut r)?;
    let kitty_keyboard = read_kitty_keyboard(&mut r)?;
    let (graphics_placements, graphics) = read_graphics(&mut r)?;

    let last_printed_char = if r.read_bool()? {
        char::from_u32(r.read_u32()?)
    } else {
        None
    };
    let protected_mode = match r.read_u8()? {
        1 => ProtectedMode::Iso,
        2 => ProtectedMode::Dec,
        _ => ProtectedMode::Off,
    };
    let answerback = r.read_string_budgeted()?;
    let xtversion = r.read_string_budgeted()?;
    let width_px = r.read_u32()?;
    let height_px = r.read_u32()?;
    let dark_scheme = match r.read_u8()? {
        1 => Some(false),
        2 => Some(true),
        _ => None,
    };
    let semantic_content = match r.read_u8()? {
        1 => SemanticContent::Prompt,
        2 => SemanticContent::Input,
        3 => SemanticContent::Output,
        _ => SemanticContent::None,
    };
    let checksum_ext = r.read_u16()?;

    if version == MIN_SUPPORTED_VERSION && r.read_bool()? {
        for _ in 0..4 {
            let _ = r.read_u32()?;
        }
        let _ = r.read_u8()?;
    }
    let selection = None;

    let mut commands = CommandState {
        log: CommandLog::default(),
        last_cwd: None,
        input_start: None,
        last_prompt_line: None,
    };
    let (default_cursor_style, cursor_style_overridden) = if version >= 3 {
        let host = read_host_config(&mut r)?;
        read_clusters(&mut r, &mut primary)?;
        read_clusters(&mut r, &mut alternate)?;
        if version >= 4 {
            commands = read_commands(&mut r, &mut primary, prim_sb_len, version)?;
        }
        palette.restore_bases(host.base, host.overridden);
        palette.set_base_fg(host.base_fg);
        palette.set_base_bg(host.base_bg);
        palette.set_base_cursor(host.base_cursor);
        palette.set_fg_overridden(host.fg_overridden);
        palette.set_bg_overridden(host.bg_overridden);
        palette.set_cursor_overridden(host.cursor_overridden);
        (host.default_cursor_style, host.cursor_style_overridden)
    } else {
        let restored = CursorStyle {
            shape: cursor_shape,
            blinking: cursor_blinking,
        };
        (CursorStyle::new(), restored != CursorStyle::new())
    };

    let terminal = Terminal {
        primary,
        alternate,
        active: active_screen,
        cursor,
        scroll_top,
        scroll_bottom,
        scroll_left,
        scroll_right,
        title,
        cursor_visible,
        parser,
        hyperlinks,
        hyperlink_ids,
        current_hyperlink,
        selection,
        g0,
        g1,
        g2,
        g3,
        shift_out,
        gr_slot,
        single_shift,
        tabstops,
        kitty_keyboard,
        response: ResponseQueue::new(),
        checksum_ext,
        modes,
        graphics,
        graphics_placements,
        cursor_style: CursorStyle {
            shape: cursor_shape,
            blinking: cursor_blinking,
        },
        default_cursor_style,
        cursor_style_overridden,
        grapheme_width_method: GraphemeWidthMethod::Unicode,
        palette,
        title_stack,
        last_printed_char,
        protected_mode,
        events: Vec::new(),
        answerback,
        xtversion,
        width_px,
        height_px,
        dark_scheme,
        semantic_content,
        commands: commands.log,
        last_cwd: commands.last_cwd,
        input_start: commands.input_start,
        viewport_offset,
        dcs,
        dcs_buf,
        default_fg,
        default_bg,
        cursor_color,
        pending_wrap,
        last_prompt_line: commands.last_prompt_line,
        in_flight_osc99: HashMap::new(),
        unidentified_osc99: None,
        context_stack: Vec::new(),
        evicted_elevated: 0,
        clipboard_policy: ClipboardPolicy::WriteOnly,
        notification_timestamps: VecDeque::new(),
    };
    offsets.allocated = r.alloc - reserved;
    Ok((terminal, offsets))
}
