/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::commands::CommandBlock;
use super::types::{
    CELL_BYTES, COMMAND_RECORD_SPINE, CURRENT_VERSION, GRID_ROW_SPINE, HYPERLINK_ID_ENTRY,
    IMAGE_ENTRY, KITTY_FLAGS_SPINE, OWNER_RUN_SPINE, PENDING_ENTRY, PLACEMENT_SPINE,
    SCROLLBACK_ROW_SPINE, STRING_SPINE, map_spine,
};
use crate::grid::Grid;
use crate::terminal::Terminal;

/// The heap an import of this terminal will commit to, charged exactly the way
/// [`import`] charges it.
///
/// Export runs this before it writes anything, so the invariant holds in both
/// directions: a checkpoint this build produces is one this build accepts.
/// Anything added to the charge list in `import` belongs here too.
pub(crate) fn allocation_cost(term: &Terminal, version: u32) -> u64 {
    let mut total: u64 = 0;
    let mut grid_cost = |grid: &Grid| {
        total = total.saturating_add(
            (grid.rows() as u64)
                .saturating_mul(grid.cols() as u64)
                .saturating_mul(CELL_BYTES),
        );
        total = total.saturating_add((grid.rows() as u64).saturating_mul(GRID_ROW_SPINE));
        let mut sb_rows: u64 = 0;
        for row in grid.scrollback_iter() {
            total = total.saturating_add((row.len() as u64).saturating_mul(CELL_BYTES));
            sb_rows += 1;
        }
        total = total.saturating_add(sb_rows.saturating_mul(SCROLLBACK_ROW_SPINE));
        for (_, _, extra, _) in grid.clusters() {
            total = total.saturating_add(extra.len() as u64);
        }
    };
    grid_cost(&term.primary);
    grid_cost(&term.alternate);

    let mut bytes: u64 = term.active_grid().cols() as u64; // tab stop bitset, decoded
    let ps = term.parser.view();
    bytes = bytes.saturating_add(ps.osc_raw.len() as u64);
    bytes = bytes.saturating_add(ps.apc_raw.len() as u64);
    bytes = bytes.saturating_add(term.dcs_buf.len() as u64);
    bytes = bytes.saturating_add((term.hyperlinks.len() as u64).saturating_mul(STRING_SPINE));
    for h in &term.hyperlinks {
        bytes = bytes.saturating_add(h.len() as u64);
    }
    bytes = bytes.saturating_add(map_spine(
        term.hyperlink_ids.len() as u64,
        HYPERLINK_ID_ENTRY,
    ));
    for k in term.hyperlink_ids.keys() {
        // The key's bytes only: its `String` handle and the `u32` id beside it
        // are already inside `HYPERLINK_ID_ENTRY`, and import charges the key
        // through `read_string_budgeted` the same way.
        bytes = bytes.saturating_add(k.len() as u64);
    }
    bytes = bytes.saturating_add(term.title.len() as u64);
    bytes =
        bytes.saturating_add((term.title_stack.items().len() as u64).saturating_mul(STRING_SPINE));
    for item in term.title_stack.items() {
        bytes = bytes.saturating_add(item.len() as u64);
    }
    bytes = bytes.saturating_add(
        (term.kitty_keyboard.stack().len() as u64).saturating_mul(KITTY_FLAGS_SPINE),
    );
    bytes = bytes.saturating_add(term.answerback.len() as u64);
    bytes = bytes.saturating_add(term.xtversion.len() as u64);
    bytes = bytes
        .saturating_add((term.graphics_placements.len() as u64).saturating_mul(PLACEMENT_SPINE));
    bytes = bytes.saturating_add(map_spine(term.graphics.images().len() as u64, IMAGE_ENTRY));
    for img in term.graphics.images().values() {
        bytes = bytes.saturating_add(img.pixels.len() as u64);
    }
    bytes = bytes.saturating_add(map_spine(
        term.graphics.pending().len() as u64,
        PENDING_ENTRY,
    ));
    for transfer in term.graphics.pending().values() {
        bytes = bytes.saturating_add(transfer.data.len() as u64);
    }
    if version >= 4 {
        let block = CommandBlock::of(term);
        bytes = bytes.saturating_add((block.runs.len() as u64).saturating_mul(OWNER_RUN_SPINE));
        bytes =
            bytes.saturating_add((block.records.len() as u64).saturating_mul(COMMAND_RECORD_SPINE));
        for rec in &block.records {
            bytes = bytes.saturating_add(rec.cwd.as_ref().map_or(0, |c| c.len() as u64));
            bytes = bytes.saturating_add(rec.input.as_ref().map_or(0, |i| i.len() as u64));
        }
        bytes = bytes.saturating_add(term.last_cwd.as_ref().map_or(0, |c| c.len() as u64));
    }
    total.saturating_add(bytes)
}

/// The heap an [`import`] of a checkpoint of `term` will commit to.
pub fn import_cost(term: &Terminal) -> u64 {
    allocation_cost(term, CURRENT_VERSION)
}

/// The heap `term` is *holding right now*, counted by capacity.
pub fn retained_cost(term: &Terminal) -> u64 {
    let mut total: u64 = 0;
    total = total.saturating_add(term.primary.retained_capacity_bytes());
    total = total.saturating_add(term.alternate.retained_capacity_bytes());
    total = total.saturating_add(term.parser.retained_capacity_bytes());
    total = total.saturating_add(term.tabstops.retained_capacity_bytes());
    total = total.saturating_add(term.kitty_keyboard.retained_capacity_bytes());
    total = total.saturating_add(term.response.retained_capacity_bytes());
    total = total.saturating_add(term.graphics.retained_capacity_bytes());
    total = total.saturating_add(term.title_stack.retained_capacity_bytes());

    total = total.saturating_add(term.title.capacity() as u64);
    total = total.saturating_add(term.answerback.capacity() as u64);
    total = total.saturating_add(term.xtversion.capacity() as u64);
    total = total.saturating_add(term.dcs_buf.capacity() as u64);

    total = total.saturating_add((term.hyperlinks.capacity() as u64).saturating_mul(STRING_SPINE));
    for h in &term.hyperlinks {
        total = total.saturating_add(h.capacity() as u64);
    }
    total = total.saturating_add(map_spine(
        term.hyperlink_ids.capacity() as u64,
        HYPERLINK_ID_ENTRY,
    ));
    for k in term.hyperlink_ids.keys() {
        total = total.saturating_add(k.capacity() as u64);
    }

    total = total.saturating_add(
        (term.graphics_placements.capacity() as u64).saturating_mul(PLACEMENT_SPINE),
    );
    total = total.saturating_add(
        (term.events.capacity() as u64)
            .saturating_mul(std::mem::size_of::<crate::terminal::TerminalEvent>() as u64),
    );
    for event in &term.events {
        total = total.saturating_add(event_payload_bytes(event));
    }
    total = total.saturating_add(term.commands.heap_bytes());
    total.saturating_add(term.last_cwd.as_ref().map_or(0, |c| c.capacity() as u64))
}

fn event_payload_bytes(event: &crate::terminal::TerminalEvent) -> u64 {
    use crate::terminal::TerminalEvent as E;
    match event {
        E::TitleChanged(s) | E::ClipboardSet(s) | E::PwdChanged(s) => s.capacity() as u64,
        E::Notification { title, body } => {
            (title.capacity() as u64).saturating_add(body.capacity() as u64)
        }
        E::StatusSet { status, text } => (status.capacity() as u64)
            .saturating_add(text.as_ref().map_or(0, |t| t.capacity() as u64)),
        E::StructuredNotification {
            id,
            title,
            body,
            app_name,
            actions,
            ..
        } => {
            let mut bytes = (title.capacity() as u64).saturating_add(body.capacity() as u64);
            if let Some(id) = id {
                bytes = bytes.saturating_add(id.capacity() as u64);
            }
            if let Some(app) = app_name {
                bytes = bytes.saturating_add(app.capacity() as u64);
            }
            for act in actions {
                bytes = bytes.saturating_add(act.capacity() as u64);
            }
            bytes
        }
        E::NotificationClose { id, .. } => id.capacity() as u64,
        E::ContextPush(f) => (f.kind.capacity() as u64)
            .saturating_add(f.name.capacity() as u64)
            .saturating_add(f.tint.as_ref().map_or(0, |t| t.capacity() as u64)),
        E::Bell
        | E::ClipboardQuery
        | E::Progress { .. }
        | E::CommandStart { .. }
        | E::CommandEnd { .. }
        | E::PromptMark
        | E::StatusClear
        | E::ContextPop
        | E::ContextClear => 0,
    }
}
