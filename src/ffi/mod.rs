// UniFFI bindings for Swift.
//
// Exposes a thread-safe wrapper (`TakoCore`) around `crate::terminal::Terminal`
// as a UniFFI `Object`, plus a per-cell `FfiCell` record so Swift can actually
// render the grid (glyph + resolved RGB colors + style flags).

use std::sync::{Mutex, MutexGuard, PoisonError};

use crate::graphics::{ImageFormat, StoredImage};
use crate::grid::{CellAttrs, Color};
use crate::modes::MouseTracking;
use crate::cursor_style::{CursorShape, CursorStyle};
use crate::palette::Palette;
use crate::terminal::checkpoint::CheckpointError;
use crate::terminal::{
    GraphemeWidthMethod, ScreenBuffer, SelectionMode, Terminal, TerminalEvent,
};

/// Default foreground/background used to resolve `Color::Default`.
/// Matches the placeholder egui demo in `src/main.rs`.
/// Upstream's defaults.
// The brand palette: a warm off-white on a near-black brown. A host that
// sets its own colours overrides these with OSC 10/11; one that does not --
// the iOS app, an embedder -- still gets the product's look rather than a
// generic grey.
const DEFAULT_FG: (u8, u8, u8) = (0xED, 0xE6, 0xDF);
const DEFAULT_BG: (u8, u8, u8) = (0x14, 0x10, 0x0E);

/// Converts a `Color` into a concrete RGB triple, resolving `Default` via
/// the caller-supplied fallback and `Indexed` via the terminal's current
/// 256-color palette (customizable at runtime through OSC 4/104).
fn resolve_color(color: Color, default: (u8, u8, u8), palette: &Palette) -> (u8, u8, u8) {
    match color {
        Color::Default => default,
        Color::Rgb(r, g, b) => (r, g, b),
        Color::Indexed(n) => palette.get(n),
    }
}

/// A single terminal cell, flattened for FFI consumption: glyph, resolved
/// foreground/background RGB, and boolean style flags.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiCell {
    /// The character as a Unicode scalar, not a string: a rendered frame
    /// carries tens of thousands of cells and a `String` per cell means a
    /// heap allocation per cell, every frame. 0 means the cell holds
    /// nothing -- the tail of a double-width pair.
    pub ch: u32,
    pub fg_r: u8,
    pub fg_g: u8,
    pub fg_b: u8,
    pub bg_r: u8,
    pub bg_g: u8,
    pub bg_b: u8,
    pub bold: bool,
    pub dim: bool,
    pub italic: bool,
    pub underline: bool,
    pub blink: bool,
    pub reverse: bool,
    pub hidden: bool,
    pub strikethrough: bool,
    pub overline: bool,
    /// SGR 4:x underline style: 0 none/legacy-single, 1 single, 2 double,
    /// 3 curly, 4 dotted, 5 dashed.
    pub underline_style: u8,
    /// Resolved underline color (falls back to the foreground).
    pub ul_r: u8,
    pub ul_g: u8,
    pub ul_b: u8,
    /// The URI of the OSC 8 hyperlink this cell is part of, or `None` if
    /// this cell isn't part of a hyperlink span.
    pub hyperlink_uri: Option<String>,
    /// True when this cell holds the left half of a double-width character.
    /// A renderer needs it to know the glyph owns the next cell too; without
    /// it, everything after a CJK character in the row is off by one.
    pub wide: bool,
    /// The whole grapheme cluster, starting with `ch`, when the cell holds
    /// more than one codepoint (combining marks, an emoji ZWJ sequence, a
    /// flag); `None` when `ch` is all of it.
    #[uniffi(default)]
    pub grapheme: Option<String>,
}

/// The whole grapheme cluster of a packed cell whose attribute bits carry
/// `PACKED_GRAPHEME`.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiGrapheme {
    /// The row's position in the payload's packed rows -- for a delta frame
    /// an index into `row_indices`, not a viewport row.
    pub row: u32,
    pub col: u32,
    /// The cluster, starting with the cell's scalar.
    pub text: String,
}

/// Mirrors `crate::terminal::GraphemeWidthMethod` (upstream's
/// `grapheme-width-method`).
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiGraphemeWidthMethod {
    Unicode,
    Legacy,
}

impl From<FfiGraphemeWidthMethod> for GraphemeWidthMethod {
    fn from(method: FfiGraphemeWidthMethod) -> Self {
        match method {
            FfiGraphemeWidthMethod::Unicode => GraphemeWidthMethod::Unicode,
            FfiGraphemeWidthMethod::Legacy => GraphemeWidthMethod::Legacy,
        }
    }
}

/// A bare RGB triple, for the host's base-color configuration
/// (`TakoCore::set_base_colors`).
#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiRgb {
    pub r: u8,
    pub g: u8,
    pub b: u8,
}

impl From<FfiRgb> for (u8, u8, u8) {
    fn from(rgb: FfiRgb) -> Self {
        (rgb.r, rgb.g, rgb.b)
    }
}

/// One indexed palette entry in the host's base-color configuration.
#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiPaletteEntry {
    pub index: u8,
    pub color: FfiRgb,
}

/// Bytes per cell in `viewport_packed`.
pub const PACKED_CELL_SIZE: usize = 16;

/// Upper bound on rows requested below the viewport. Sub-cell translation
/// never exposes more than one row; anything beyond that is a caller bug,
/// not a frame to allocate.
const MAX_OVERSCAN_ROWS: u32 = 2;

pub const PACKED_BOLD: u16 = 1 << 0;
pub const PACKED_DIM: u16 = 1 << 1;
pub const PACKED_ITALIC: u16 = 1 << 2;
pub const PACKED_UNDERLINE: u16 = 1 << 3;
pub const PACKED_BLINK: u16 = 1 << 4;
pub const PACKED_REVERSE: u16 = 1 << 5;
pub const PACKED_HIDDEN: u16 = 1 << 6;
pub const PACKED_STRIKETHROUGH: u16 = 1 << 7;
pub const PACKED_OVERLINE: u16 = 1 << 8;
pub const PACKED_WIDE: u16 = 1 << 9;
/// The cell holds a multi-codepoint grapheme cluster; the frame's
/// `graphemes` carries its text.
pub const PACKED_GRAPHEME: u16 = 1 << 10;

/// The whole cluster of `cell` when it has more than one codepoint.
fn grapheme_text(grid: &crate::grid::Grid, cell: &crate::grid::Cell) -> Option<String> {
    let extra = grid.grapheme(cell);
    if extra.is_empty() || cell.is_wide_spacer {
        return None;
    }
    let mut text = String::with_capacity(cell.char.len_utf8() + extra.len());
    text.push(cell.char);
    text.push_str(extra);
    Some(text)
}

fn cell_to_ffi(
    cell: &crate::grid::Cell,
    hyperlink_uri: Option<String>,
    grapheme: Option<String>,
    palette: &Palette,
    default_fg: (u8, u8, u8),
    default_bg: (u8, u8, u8),
) -> FfiCell {
    let (fg_r, fg_g, fg_b) = resolve_color(cell.fg, default_fg, palette);
    let (bg_r, bg_g, bg_b) = resolve_color(cell.bg, default_bg, palette);
    let (ul_r, ul_g, ul_b) = resolve_color(cell.underline_color, (fg_r, fg_g, fg_b), palette);
    FfiCell {
        // The tail of a double-width pair carries no character. Reporting a
        // space for it would advance the row by a cell the glyph already
        // covers.
        ch: if cell.is_wide_spacer {
            0
        } else if cell.char == '\0' {
            u32::from(' ')
        } else {
            u32::from(cell.char)
        },
        fg_r,
        fg_g,
        fg_b,
        bg_r,
        bg_g,
        bg_b,
        bold: cell.attrs.contains(CellAttrs::BOLD),
        dim: cell.attrs.contains(CellAttrs::DIM),
        italic: cell.attrs.contains(CellAttrs::ITALIC),
        underline: cell.attrs.contains(CellAttrs::UNDERLINE),
        blink: cell.attrs.contains(CellAttrs::BLINK),
        reverse: cell.attrs.contains(CellAttrs::REVERSE),
        hidden: cell.attrs.contains(CellAttrs::HIDDEN),
        strikethrough: cell.attrs.contains(CellAttrs::STRIKETHROUGH),
        overline: cell.attrs.contains(CellAttrs::OVERLINE),
        underline_style: cell.underline_style,
        ul_r,
        ul_g,
        ul_b,
        hyperlink_uri,
        wide: cell.is_wide_spacer_head,
        grapheme,
    }
}

/// UniFFI-exported wrapper around `Terminal`. UniFFI objects are shared via
/// `Arc<Self>` across the FFI boundary, so mutability is achieved with an
/// internal `Mutex`.
/// Mirrors `crate::terminal::SelectionMode` for FFI consumption.
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiSelectionMode {
    Linear,
    Rectangular,
}

impl From<FfiSelectionMode> for SelectionMode {
    fn from(mode: FfiSelectionMode) -> Self {
        match mode {
            FfiSelectionMode::Linear => SelectionMode::Linear,
            FfiSelectionMode::Rectangular => SelectionMode::Rectangular,
        }
    }
}

impl From<SelectionMode> for FfiSelectionMode {
    fn from(mode: SelectionMode) -> Self {
        match mode {
            SelectionMode::Linear => FfiSelectionMode::Linear,
            SelectionMode::Rectangular => FfiSelectionMode::Rectangular,
        }
    }
}

/// The normalized `(start, end)` bounds of the current selection, in
/// reading order, for a Swift renderer to highlight.
#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiSelectionRange {
    pub start_row: u32,
    pub start_col: u32,
    pub end_row: u32,
    pub end_col: u32,
    pub mode: FfiSelectionMode,
}

/// Mirrors `crate::modes::MouseTracking` for FFI consumption.
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiMouseTracking {
    Off,
    Normal,
    ButtonEvent,
    AnyEvent,
}

impl From<MouseTracking> for FfiMouseTracking {
    fn from(mode: MouseTracking) -> Self {
        match mode {
            MouseTracking::Off => FfiMouseTracking::Off,
            MouseTracking::Normal => FfiMouseTracking::Normal,
            MouseTracking::ButtonEvent => FfiMouseTracking::ButtonEvent,
            MouseTracking::AnyEvent => FfiMouseTracking::AnyEvent,
        }
    }
}

/// Snapshot of the terminal's DEC private-mode state -- what a Swift
/// renderer/input layer needs to decide how to encode mouse events, whether
/// to auto-wrap, whether pasted text should be bracketed, etc.
#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiTerminalModes {
    pub autowrap: bool,
    pub origin_mode: bool,
    pub cursor_key_app_mode: bool,
    pub mouse_tracking: FfiMouseTracking,
    pub mouse_utf8: bool,
    pub mouse_sgr: bool,
    pub focus_events: bool,
    pub bracketed_paste: bool,
    pub alternate_screen: bool,
    pub alternate_scroll: bool,
}

/// Mirrors `crate::graphics::ImageFormat` for FFI consumption.
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiImageFormat {
    Rgb,
    Rgba,
    Png,
}

impl From<ImageFormat> for FfiImageFormat {
    fn from(format: ImageFormat) -> Self {
        match format {
            ImageFormat::Rgb => FfiImageFormat::Rgb,
            ImageFormat::Rgba => FfiImageFormat::Rgba,
            ImageFormat::Png => FfiImageFormat::Png,
        }
    }
}

/// A Kitty Graphics image, decoded and ready for a Swift renderer to upload
/// as a texture: `pixels` is raw RGB/RGBA data for those formats, or the
/// verbatim PNG file bytes for `Png`.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiStoredImage {
    pub format: FfiImageFormat,
    pub width: u32,
    pub height: u32,
    pub pixels: Vec<u8>,
}

#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiGraphicsImageMetadata {
    pub format: FfiImageFormat,
    pub width: u32,
    pub height: u32,
    pub generation: u64,
}

impl From<&StoredImage> for FfiStoredImage {
    fn from(image: &StoredImage) -> Self {
        Self {
            format: image.format.into(),
            width: image.width,
            height: image.height,
            pixels: image.pixels.clone(),
        }
    }
}

/// Where a Kitty Graphics image is displayed, in cell coordinates.
#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiGraphicsPlacement {
    pub image_id: u32,
    pub placement_id: u32,
    pub row: u32,
    pub col: u32,
}

/// Mirrors `crate::cursor_style::CursorShape` for FFI consumption.
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiCursorShape {
    Block,
    Underline,
    Bar,
}

impl From<FfiCursorShape> for CursorShape {
    fn from(shape: FfiCursorShape) -> Self {
        match shape {
            FfiCursorShape::Block => CursorShape::Block,
            FfiCursorShape::Underline => CursorShape::Underline,
            FfiCursorShape::Bar => CursorShape::Bar,
        }
    }
}

impl From<CursorShape> for FfiCursorShape {
    fn from(shape: CursorShape) -> Self {
        match shape {
            CursorShape::Block => FfiCursorShape::Block,
            CursorShape::Underline => FfiCursorShape::Underline,
            CursorShape::Bar => FfiCursorShape::Bar,
        }
    }
}

/// The cursor's current visual style (DECSCUSR), for a Swift renderer.
#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiCursorStyle {
    pub shape: FfiCursorShape,
    pub blinking: bool,
}

impl From<CursorStyle> for FfiCursorStyle {
    fn from(style: CursorStyle) -> Self {
        Self {
            shape: style.shape.into(),
            blinking: style.blinking,
        }
    }
}

/// Host-visible side effect drained via `takeEvents()`.
#[derive(uniffi::Enum, Debug, Clone, PartialEq, Eq)]
pub enum FfiEvent {
    Bell,
    TitleChanged { title: String },
    ClipboardSet { text: String },
    ClipboardQuery,
    Notification { title: String, body: String },
    PwdChanged { url: String },
    Progress { state: u8, value: Option<u8> },
    /// OSC 133;C -- a command started running.
    CommandStart,
    /// OSC 133;D -- a command finished, with its exit code when reported.
    CommandEnd { exit_code: Option<i32> },
}

impl From<TerminalEvent> for FfiEvent {
    fn from(e: TerminalEvent) -> Self {
        match e {
            TerminalEvent::Bell => FfiEvent::Bell,
            TerminalEvent::TitleChanged(title) => FfiEvent::TitleChanged { title },
            TerminalEvent::ClipboardSet(text) => FfiEvent::ClipboardSet { text },
            TerminalEvent::ClipboardQuery => FfiEvent::ClipboardQuery,
            TerminalEvent::Notification { title, body } => FfiEvent::Notification { title, body },
            TerminalEvent::PwdChanged(url) => FfiEvent::PwdChanged { url },
            TerminalEvent::Progress { state, value } => FfiEvent::Progress { state, value },
            TerminalEvent::CommandStart => FfiEvent::CommandStart,
            TerminalEvent::CommandEnd { exit_code } => FfiEvent::CommandEnd { exit_code },
        }
    }
}

/// Everything a renderer needs for one frame, in a single FFI call.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FfiSnapshot {
    pub cols: u32,
    pub rows: u32,
    pub cursor_row: u32,
    pub cursor_col: u32,
    pub cursor_visible: bool,
    pub cursor_style: FfiCursorStyle,
    pub title: String,
    pub modes: FfiTerminalModes,
    pub viewport_offset: u32,
    pub scrollback_len: u32,
    /// Viewport rows that changed since the previous snapshot.
    pub damaged_rows: Vec<u32>,
    pub selection: Option<FfiSelectionRange>,
    pub graphics_placements: Vec<FfiGraphicsPlacement>,
}

/// Everything a renderer needs for one frame, including packed viewport cells,
/// captured under a single terminal lock to eliminate snapshot/viewport_packed tearing.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FfiRenderFrame {
    pub snapshot: FfiSnapshot,
    pub packed_cells: Vec<u8>,
    /// The engine generation this frame was taken from, read in the same
    /// critical section as the geometry and the cells.
    ///
    /// A checkpoint import replaces the whole engine; a host that publishes
    /// geometry from one call and cells from another can straddle that
    /// replacement. Carrying the epoch inside the frame is what makes
    /// "this frame is stale" observable rather than inferred.
    pub epoch: u64,
    /// Clusters of the cells marked `PACKED_GRAPHEME`, in payload order.
    #[uniffi(default)]
    pub graphemes: Vec<FfiGrapheme>,
}

/// One frame plus the rows immediately *below* the viewport, so a host can
/// translate the whole grid by a fraction of a cell and still have something
/// to draw in the strip that translation exposes at the bottom edge.
///
/// `packed_cells` holds `snapshot.rows + overscan_rows` rows in the layout
/// `viewport_packed` documents; the first `snapshot.rows` of them are the
/// viewport itself, so a host that ignores `overscan_rows` sees exactly the
/// frame `render_frame` would have given it.
///
/// Everything else in `snapshot` -- cursor position, geometry, selection --
/// stays viewport-relative and is unaffected by the extra rows.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FfiRenderFrameOverscan {
    pub snapshot: FfiSnapshot,
    pub packed_cells: Vec<u8>,
    pub overscan_rows: u32,
    /// The engine generation this frame was taken from, on the same terms as
    /// `FfiRenderFrame::epoch` and read in the same critical section.
    ///
    /// Carried here rather than left to the caller precisely because the
    /// caller cannot get it right: a host that turns this into an
    /// `FfiRenderFrame` by asking the engine for its epoch afterwards has
    /// already left the lock, and a checkpoint import landing in between
    /// would stamp cells from the old engine with the new generation --
    /// which is the straddle the epoch exists to make visible.
    pub epoch: u64,
    /// Clusters of the cells marked `PACKED_GRAPHEME`, in payload order.
    #[uniffi(default)]
    pub graphemes: Vec<FfiGrapheme>,
}

/// A contiguous run of viewport rows carried by one delta payload.
///
/// `start` is a viewport row index (0 = top row as currently scrolled),
/// `count` the number of consecutive rows. Ranges are ascending and never
/// overlap, so a host can turn them straight into texture-upload regions.
#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiRowRange {
    pub start: u32,
    pub count: u32,
}

/// Why a delta frame had to carry the whole viewport instead of just the
/// rows that moved. `Delta` means it did not: the payload is incremental.
///
/// Every value other than `Delta` is a hard "throw away what you have":
/// the host's row cache no longer describes this terminal, so the payload
/// is a full resync it must adopt wholesale.
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiResyncReason {
    /// Incremental payload: only the listed rows changed.
    Delta,
    /// No delta has ever been handed out for this core.
    FirstFrame,
    /// The caller's `sinceVersion` is not the version we last handed it --
    /// it missed a frame (dropped, crashed, or a second renderer exists).
    VersionMismatch,
    /// The grid geometry changed; old row indices mean nothing now.
    Resized,
    /// The viewport scrolled over scrollback, so every row index moved.
    ViewportScrolled,
    /// Primary <-> alternate screen switch: a different grid entirely.
    ScreenSwitched,
    /// The terminal was reset and replaced.
    Reset,
    /// Every row is dirty (`markAllDamaged`, a full repaint, a resize the
    /// terminal handled internally) -- cache-invalidation equivalent, so a
    /// delta would be the whole viewport anyway.
    FullDamage,
    /// Another consumer (`takeDamage`, `snapshot`, `renderFrame`) drained
    /// the terminal's damage between two delta calls, so the rows we can
    /// still see no longer describe everything that changed. See the
    /// ownership rule on `render_frame_delta`.
    DamageOwnershipLost,
}

/// One frame for a host that keeps its own row cache: frame metadata plus
/// either the whole packed viewport or only the packed rows that changed,
/// captured under a single terminal lock.
///
/// The payload is self-describing on purpose -- a host never has to infer
/// geometry from the byte count:
///
/// * `row_indices` -- the viewport row index of each packed row, in payload
///   order, ascending. `row_ranges` is the same list collapsed into runs.
/// * `packed_cells` -- `row_indices.len() * row_stride` bytes, rows back to
///   back, each row `cols` cells of `cell_stride` bytes in the layout
///   documented on `viewport_packed`.
/// * `full_resync` -- `row_indices` is `0..rows` and the payload replaces
///   the host's cache. `resync_reason` says why.
/// * `frame_version` -- monotonic, strictly increasing, never 0. Pass it
///   back as the next call's `since_version`.
/// * `base_version` -- the version this delta applies on top of, or 0 for a
///   full resync (which applies on top of nothing).
///
/// `snapshot.damaged_rows` is set to `row_indices`, so the record cannot
/// disagree with itself.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FfiRenderFrameDelta {
    /// Cursor, title, modes, selection, graphics -- always current, even
    /// when no cell changed.
    pub snapshot: FfiSnapshot,
    pub frame_version: u64,
    pub base_version: u64,
    pub full_resync: bool,
    pub resync_reason: FfiResyncReason,
    pub cols: u32,
    pub rows: u32,
    /// Bytes per packed cell (`PACKED_CELL_SIZE`).
    pub cell_stride: u32,
    /// Bytes per packed row (`cols * cell_stride`).
    pub row_stride: u32,
    pub row_indices: Vec<u32>,
    pub row_ranges: Vec<FfiRowRange>,
    pub packed_cells: Vec<u8>,
    /// Clusters of the cells marked `PACKED_GRAPHEME`, in payload order.
    #[uniffi(default)]
    pub graphemes: Vec<FfiGrapheme>,
}

/// Per-core bookkeeping for the delta consumer.
///
/// Behind its own lock, always taken *after* the terminal lock (the only
/// order any method here uses, so it cannot deadlock), and held together
/// with it while a delta frame is built -- the payload and the state it
/// records are one atomic step.
#[derive(Debug, Default)]
struct DeltaState {
    /// Version handed out by the last `render_frame_delta`; 0 = none yet.
    version: u64,
    started: bool,
    cols: u32,
    rows: u32,
    viewport_offset: u32,
    alternate: bool,
    /// `reset()` replaced the terminal wholesale.
    reset_pending: bool,
    /// Some other consumer drained the damage flags since the last delta.
    foreign_drain: bool,
}

/// Keys a host can send; mirrors `key_encode::Key` (the char variant is
/// carried separately since UniFFI enums can't hold a `char`).
#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiKey {
    Enter, Tab, Backspace, Escape, Space,
    Up, Down, Right, Left, Home, End, PageUp, PageDown, Insert, Delete,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
    KeypadEnter, KeypadPlus, KeypadMinus, KeypadMultiply, KeypadDivide,
    Keypad0, Keypad1, Keypad2, Keypad3, Keypad4, Keypad5, Keypad6, Keypad7, Keypad8, Keypad9,
    /// The modifier keys as events in their own right (only ever reported
    /// under the Kitty protocol's report-all flag).
    ShiftLeft, ShiftRight, ControlLeft, ControlRight, AltLeft, AltRight, MetaLeft, MetaRight,
    /// Text with no key behind it (e.g. IME-composed text with no
    /// originating physical key).
    Unidentified,
    /// A printable character: the codepoint travels in `FfiKeyEvent::text`.
    Character,
}

/// A key event to encode for the PTY.
#[derive(uniffi::Record, Debug, Clone, PartialEq, Eq)]
pub struct FfiKeyEvent {
    pub key: FfiKey,
    /// The typed character when `key` is `Character`; ignored otherwise.
    /// This is the character *with* modifiers applied -- `A`, not `a`.
    ///
    /// For any key, a non-empty value here also carries a dead-key/IME
    /// commit: the text this event actually produced, which wins over the
    /// key's default bytes (mirrors `key_encode::KeyEvent::text`).
    pub text: String,
    /// Which key this physically is, as the ASCII it would type on a US
    /// layout. On a Cyrillic layout the `c` key types U+0441 and its
    /// unshifted form is U+0441 too, so without this `ctrl+c` on a Russian
    /// layout produces the letter rather than 0x03.
    pub physical_text: String,
    /// The same key with no modifiers applied, when the host can report it.
    ///
    /// The Kitty keyboard protocol identifies a key by its base codepoint
    /// and reports shift separately. Without this, a shifted key is sent
    /// under the shifted codepoint and a protocol-aware shell drops it --
    /// which is how shift came to type nothing at all.
    pub unshifted_text: String,
    pub shift: bool,
    pub alt: bool,
    pub ctrl: bool,
    pub super_key: bool,
    pub press: bool,
    pub repeat: bool,
    /// True while a dead-key/IME composition is in progress and this event
    /// has not committed text yet (mirrors `key_encode::KeyEvent::composing`).
    pub composing: bool,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiMouseButton {
    Left, Middle, Right, WheelUp, WheelDown, WheelLeft, WheelRight, None,
}

#[derive(uniffi::Enum, Debug, Clone, Copy, PartialEq, Eq)]
pub enum FfiMouseAction {
    Press, Release, Motion,
}

/// A mouse event to encode for the PTY, in cell coordinates.
#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiMouseEvent {
    pub button: FfiMouseButton,
    pub action: FfiMouseAction,
    pub shift: bool,
    pub alt: bool,
    pub ctrl: bool,
    pub col: u32,
    pub row: u32,
}

/// Everything the host needs to know right after handing the parser a chunk
/// of PTY bytes, gathered under the SAME lock as the parse itself: the device
/// replies to write back, the events that fired, whether a repaint is now
/// pending, and whether the app is mid Synchronized Output frame.
///
/// `has_damage` is deliberately non-draining -- `render_frame` is still the
/// one call that consumes damage, so a host can feed several chunks, see the
/// signal go true, and coalesce them into a single frame without losing rows.
#[derive(uniffi::Record, Debug, Clone, PartialEq)]
pub struct FfiFeedOutcome {
    /// Device replies (DA/DSR/XTVERSION/...) to write back to the PTY.
    pub output: Vec<u8>,
    /// Host-visible events queued by this feed (bell, title, clipboard, ...).
    pub events: Vec<FfiEvent>,
    /// Whether a repaint is pending. Does NOT clear the damage flags.
    pub has_damage: bool,
    /// Whether mode 2026 is open after this feed, i.e. the app has not yet
    /// finished the frame and nothing should be painted on its own.
    pub synchronized_output_active: bool,
    /// The engine generation this outcome was produced under.
    ///
    /// Outcomes are captured off the main thread and applied later, so an
    /// outcome parsed before a checkpoint import can reach the host after it.
    /// A host compares this against the engine's current epoch and drops what
    /// no longer describes the terminal it has.
    pub epoch: u64,
}

/// What a checkpoint declares about itself, without decoding it.
#[derive(uniffi::Record, Debug, Clone, Copy, PartialEq, Eq)]
pub struct FfiCheckpointInfo {
    pub version: u32,
    pub flags: u32,
    pub cols: u32,
    pub rows: u32,
    pub payload_len: u32,
}

/// The typed failures of the checkpoint API.
///
/// A bool cannot tell "corrupt payload" from "valid payload of a version I
/// cannot read", and those two need different decisions from a peer: retry or
/// negotiate down versus fail explicitly.
#[derive(Debug, thiserror::Error, uniffi::Error, PartialEq, Eq)]
pub enum TakoCheckpointError {
    #[error("null argument")]
    NullArgument,
    #[error("checkpoint is {size} bytes, limit is {limit}")]
    TooLarge { size: u64, limit: u64 },
    #[error("unsupported checkpoint version {version}")]
    UnsupportedVersion { version: u32 },
    #[error("corrupt checkpoint: {reason}")]
    Corrupt { reason: String },
}

impl From<CheckpointError> for TakoCheckpointError {
    fn from(err: CheckpointError) -> Self {
        match err {
            CheckpointError::UnsupportedVersion(version) => Self::UnsupportedVersion { version },
            CheckpointError::TooLarge { size, limit } => Self::TooLarge { size, limit },
            other => Self::Corrupt {
                reason: other.to_string(),
            },
        }
    }
}

/// The engine plus the generation counter that says which engine it is.
///
/// The two live under one mutex on purpose. A checkpoint import replaces the
/// whole `Terminal`, and every reader -- a render frame, the scroll position,
/// the buffer text -- reaches the engine through this same lock. Publishing
/// the epoch anywhere else (a host-side coordinator, a second mutex) would
/// leave those readers unable to tell which engine they just read.
struct Engine {
    terminal: Terminal,
    epoch: u64,
}

impl std::ops::Deref for Engine {
    type Target = Terminal;

    fn deref(&self) -> &Terminal {
        &self.terminal
    }
}

impl std::ops::DerefMut for Engine {
    fn deref_mut(&mut self) -> &mut Terminal {
        &mut self.terminal
    }
}

/// Locks `mutex`, recovering the guard instead of panicking if it is
/// poisoned.
///
/// A panic while some other call held this lock (an engine bug, not data
/// corruption -- a `Mutex` only ever unlocks by dropping the guard, so
/// nothing is left half-written) would otherwise poison it, and every call
/// after that would panic too for the rest of the process's life. Swift only
/// ever sees one `TakoCore`; there is no way for it to replace a poisoned
/// one, so that failure mode is permanent for the session.
fn lock_recover<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

#[derive(uniffi::Object)]
pub struct TakoCore {
    inner: Mutex<Engine>,
    /// Delta-renderer bookkeeping; see `DeltaState` for the lock order.
    delta: Mutex<DeltaState>,
}

#[uniffi::export]
impl TakoCore {
    #[uniffi::constructor]
    pub fn new(cols: u32, rows: u32) -> Self {
        Self {
            inner: Mutex::new(Engine {
                terminal: Terminal::new(cols as usize, rows as usize),
                epoch: 1,
            }),
            delta: Mutex::new(DeltaState::default()),
        }
    }

    /// Export the terminal state as a native versioned binary checkpoint.
    ///
    /// Kept for source compatibility. Returns an empty buffer -- which is not
    /// a valid checkpoint and does not verify -- where the typed
    /// `checkpoint_export` would say why.
    pub fn checkpoint(&self) -> Vec<u8> {
        let terminal = lock_recover(&self.inner);
        terminal.export_checkpoint().unwrap_or_default()
    }

    /// Restore the terminal state from a native checkpoint.
    /// Returns true on success, false if the payload is invalid or corrupted.
    pub fn restore(&self, bytes: Vec<u8>) -> bool {
        self.checkpoint_import(bytes).is_ok()
    }

    /// Verify the integrity and version of a native checkpoint payload.
    pub fn verify_checkpoint(&self, bytes: Vec<u8>) -> bool {
        Terminal::verify_checkpoint(&bytes)
    }

    /// The checkpoint container version this build writes.
    pub fn checkpoint_version(&self) -> u32 {
        Terminal::checkpoint_version()
    }

    /// Whether this build can import that container version.
    pub fn checkpoint_supports(&self, version: u32) -> bool {
        Terminal::checkpoint_supports(version)
    }

    /// Export bounded by a caller-supplied byte cap.
    ///
    /// The effective limit is the smaller of `max_bytes` and the 64 MiB wire
    /// cap, and `max_bytes` of 0 means "no caller limit" -- the wire cap alone.
    /// The limit covers the whole blob, container header included, so a
    /// returned checkpoint always fits the cap the caller negotiated.
    /// Exceeding it fails with `TooLarge { size, limit }` rather than
    /// allocating past it. A failed export leaves the terminal exactly as it
    /// was -- nothing truncated, nothing cleared, nothing reset.
    ///
    /// `flags` is reserved by the v1 container and must be 0.
    pub fn checkpoint_export(
        &self,
        flags: u32,
        max_bytes: u64,
    ) -> Result<Vec<u8>, TakoCheckpointError> {
        if flags != 0 {
            return Err(TakoCheckpointError::Corrupt {
                reason: format!("unknown export flags {flags}"),
            });
        }
        let terminal = lock_recover(&self.inner);
        Ok(terminal.export_checkpoint_limited(max_bytes)?)
    }

    /// `checkpoint_export` in a chosen container version: the newest one the
    /// peer's `checkpoint_supports` accepts, so upgrading one side never makes
    /// the other refuse its checkpoints. 0 is `checkpoint_version()`; a
    /// version this build cannot write fails with `UnsupportedVersion`.
    pub fn checkpoint_export_version(
        &self,
        version: u32,
        max_bytes: u64,
    ) -> Result<Vec<u8>, TakoCheckpointError> {
        let terminal = lock_recover(&self.inner);
        Ok(terminal.export_checkpoint_version(version, max_bytes)?)
    }

    /// Replace the terminal from a checkpoint, atomically.
    ///
    /// Fail-intact: the whole state is decoded into a new engine first and
    /// only a complete one is swapped in, so a rejected import leaves the
    /// destination byte-identical to what it was. The epoch is published in
    /// the same critical section as the swap, so no reader can observe the new
    /// engine under the old generation or the reverse.
    pub fn checkpoint_import(&self, blob: Vec<u8>) -> Result<(), TakoCheckpointError> {
        if blob.is_empty() {
            return Err(TakoCheckpointError::NullArgument);
        }
        let mut engine = lock_recover(&self.inner);
        let mut delta = lock_recover(&self.delta);
        engine.terminal.import_checkpoint(&blob)?;
        engine.epoch = engine.epoch.wrapping_add(1);
        delta.reset_pending = true;
        Ok(())
    }

    /// A checkpoint's version and geometry, without committing to importing
    /// it -- so a host can decide first.
    pub fn checkpoint_inspect(&self, blob: Vec<u8>) -> Result<FfiCheckpointInfo, TakoCheckpointError> {
        if blob.is_empty() {
            return Err(TakoCheckpointError::NullArgument);
        }
        let info = Terminal::inspect_checkpoint(&blob)?;
        Ok(FfiCheckpointInfo {
            version: info.version,
            flags: info.flags,
            cols: info.cols,
            rows: info.rows,
            payload_len: info.payload_len,
        })
    }

    /// The current engine generation. Bumped by every checkpoint import.
    pub fn state_epoch(&self) -> u64 {
        lock_recover(&self.inner).epoch
    }

    /// Feeds raw PTY output bytes into the terminal's VT100/ANSI parser.
    pub fn feed(&self, bytes: Vec<u8>) {
        lock_recover(&self.inner).feed(&bytes);
    }

    /// Feeds PTY bytes and reports the result of that feed in one shot,
    /// taking the terminal lock exactly once: parse, drain output, drain
    /// events, then observe damage and Synchronized Output state.
    ///
    /// The point is atomicity -- `feed` + `take_output` + `take_events` +
    /// `is_synchronized_output_active` as four separate calls lets another
    /// feed slip in between them, so the host can see events belonging to a
    /// mode state that no longer holds. Damage is only OBSERVED here, never
    /// drained; `render_frame` remains the single consumer of damaged rows.
    pub fn feed_with_outcome(&self, bytes: Vec<u8>) -> FfiFeedOutcome {
        let mut engine = lock_recover(&self.inner);
        engine.feed(&bytes);
        let output = engine.take_output();
        let events = engine.take_events().into_iter().map(FfiEvent::from).collect();
        FfiFeedOutcome {
            output,
            events,
            has_damage: engine.has_damage(),
            synchronized_output_active: engine.is_synchronized_output(),
            // Same critical section as the parse: the epoch this outcome was
            // produced under cannot change between them.
            epoch: engine.epoch,
        }
    }

    /// Drains and returns any queued device-reply bytes (DA/DSR/XTVERSION/
    /// Kitty-keyboard-query responses) for the caller to write back to the
    /// PTY's input.
    pub fn take_output(&self) -> Vec<u8> {
        lock_recover(&self.inner).take_output()
    }

    /// Current DEC private-mode state (autowrap, mouse tracking,
    /// bracketed paste, focus events, ...).
    pub fn modes(&self) -> FfiTerminalModes {
        let terminal = lock_recover(&self.inner);
        let modes = terminal.modes();
        FfiTerminalModes {
            autowrap: modes.autowrap,
            origin_mode: modes.origin_mode,
            cursor_key_app_mode: modes.cursor_key_app_mode,
            mouse_tracking: modes.mouse_tracking.into(),
            mouse_utf8: modes.mouse_utf8,
            mouse_sgr: modes.mouse_sgr,
            focus_events: modes.focus_events,
            bracketed_paste: modes.bracketed_paste,
            alternate_screen: terminal.active_screen() == ScreenBuffer::Alternate,
            alternate_scroll: modes.alternate_scroll,
        }
    }

    /// Whether a Synchronized Output frame (mode 2026) is currently open --
    /// a host-side redraw trigger that doesn't go through `take_damage`
    /// (a cursor blink timer, say) needs this to know not to paint a real,
    /// unfinished frame the app never intended to be visible on its own.
    pub fn is_synchronized_output_active(&self) -> bool {
        lock_recover(&self.inner).is_synchronized_output()
    }

    /// The Kitty keyboard protocol's currently active progressive-
    /// enhancement flags, as a raw bitmask.
    pub fn kitty_keyboard_flags(&self) -> u8 {
        lock_recover(&self.inner).kitty_keyboard_flags()
    }

    /// Currently live Kitty Graphics placements, in display order.
    pub fn graphics_placements(&self) -> Vec<FfiGraphicsPlacement> {
        lock_recover(&self.inner)
            .graphics_placements()
            .iter()
            .map(|p| FfiGraphicsPlacement {
                image_id: p.image_id,
                placement_id: p.placement_id,
                row: p.row as u32,
                col: p.col as u32,
            })
            .collect()
    }

    /// The decoded image data for a Kitty Graphics image id, ready to
    /// upload as a texture. `None` if no such image is stored.
    pub fn graphics_image(&self, image_id: u32) -> Option<FfiStoredImage> {
        lock_recover(&self.inner)
            .graphics_image(image_id)
            .map(FfiStoredImage::from)
    }

    /// Metadata for a stored Kitty Graphics image, without cloning payload
    /// bytes. `None` if no such image id is currently stored.
    pub fn graphics_image_metadata(&self, image_id: u32) -> Option<FfiGraphicsImageMetadata> {
        lock_recover(&self.inner).graphics_image(image_id).map(|image| {
            FfiGraphicsImageMetadata {
                format: image.format.into(),
                width: image.width,
                height: image.height,
                generation: image.generation,
            }
        })
    }

    /// Drains queued host-visible events (bell, clipboard, notifications).
    pub fn take_events(&self) -> Vec<FfiEvent> {
        lock_recover(&self.inner)
            .take_events()
            .into_iter()
            .map(FfiEvent::from)
            .collect()
    }

    /// Encodes a key event into the bytes to write to the PTY, honoring
    /// the terminal's live DECCKM and Kitty-keyboard state. Empty when the
    /// event produces no input (e.g. a release in legacy mode).
    pub fn encode_key(&self, event: FfiKeyEvent) -> Vec<u8> {
        use crate::key_encode::{encode, EncodeConfig, Key, KeyEvent, Mods, OptionAsAlt};
        let terminal = lock_recover(&self.inner);
        let key = match event.key {
            FfiKey::Enter => Key::Enter,
            FfiKey::Tab => Key::Tab,
            FfiKey::Backspace => Key::Backspace,
            FfiKey::Escape => Key::Escape,
            FfiKey::Space => Key::Space,
            FfiKey::Up => Key::Up,
            FfiKey::Down => Key::Down,
            FfiKey::Right => Key::Right,
            FfiKey::Left => Key::Left,
            FfiKey::Home => Key::Home,
            FfiKey::End => Key::End,
            FfiKey::PageUp => Key::PageUp,
            FfiKey::PageDown => Key::PageDown,
            FfiKey::Insert => Key::Insert,
            FfiKey::Delete => Key::Delete,
            FfiKey::F1 => Key::F1,
            FfiKey::F2 => Key::F2,
            FfiKey::F3 => Key::F3,
            FfiKey::F4 => Key::F4,
            FfiKey::F5 => Key::F5,
            FfiKey::F6 => Key::F6,
            FfiKey::F7 => Key::F7,
            FfiKey::F8 => Key::F8,
            FfiKey::F9 => Key::F9,
            FfiKey::F10 => Key::F10,
            FfiKey::F11 => Key::F11,
            FfiKey::F12 => Key::F12,
            FfiKey::KeypadEnter => Key::KeypadEnter,
            FfiKey::KeypadPlus => Key::KeypadPlus,
            FfiKey::KeypadMinus => Key::KeypadMinus,
            FfiKey::KeypadMultiply => Key::KeypadMultiply,
            FfiKey::KeypadDivide => Key::KeypadDivide,
            FfiKey::Keypad0 => Key::Keypad0,
            FfiKey::Keypad1 => Key::Keypad1,
            FfiKey::Keypad2 => Key::Keypad2,
            FfiKey::Keypad3 => Key::Keypad3,
            FfiKey::Keypad4 => Key::Keypad4,
            FfiKey::Keypad5 => Key::Keypad5,
            FfiKey::Keypad6 => Key::Keypad6,
            FfiKey::Keypad7 => Key::Keypad7,
            FfiKey::Keypad8 => Key::Keypad8,
            FfiKey::Keypad9 => Key::Keypad9,
            FfiKey::ShiftLeft => Key::ShiftLeft,
            FfiKey::ShiftRight => Key::ShiftRight,
            FfiKey::ControlLeft => Key::ControlLeft,
            FfiKey::ControlRight => Key::ControlRight,
            FfiKey::AltLeft => Key::AltLeft,
            FfiKey::AltRight => Key::AltRight,
            FfiKey::MetaLeft => Key::MetaLeft,
            FfiKey::MetaRight => Key::MetaRight,
            FfiKey::Unidentified => Key::Unidentified,
            FfiKey::Character => {
                // A key's identity is the base key, not what the OS produced
                // once it applied the modifiers. macOS hands us
                // `NSEvent.characters` already folded: for ctrl+c that is
                // U+0003, not "c". Taking it as the key made ctrl+c a press
                // of a control character, which appears in no
                // control-sequence table, so the interrupt byte never
                // reached the pty and nothing could be interrupted.
                //
                // `unshiftedText` is `charactersIgnoringModifiers`, which is
                // exactly the base key. The produced text still travels
                // separately in `text` below, so ordinary typing -- shift
                // included -- is unchanged.
                let base = event
                    .unshifted_text
                    .chars()
                    .next()
                    .or_else(|| event.text.chars().next());
                match base {
                    Some(ch) => Key::Char(ch),
                    None => return Vec::new(),
                }
            }
        };
        let mut mods = Mods::empty();
        if event.shift {
            mods |= Mods::SHIFT;
        }
        if event.alt {
            mods |= Mods::ALT;
        }
        if event.ctrl {
            mods |= Mods::CTRL;
        }
        if event.super_key {
            mods |= Mods::SUPER;
        }
        let config = EncodeConfig {
            cursor_key_app_mode: terminal.modes().cursor_key_app_mode,
            keypad_app_mode: false,
            kitty_flags: terminal.kitty_keyboard_flags(),
            alt_esc_prefix: true,
            macos_option_as_alt: OptionAsAlt::default(),
            backarrow_key_mode: false,
            modify_other_keys_state_2: false,
            ignore_keypad_with_numlock: true,
        };
        encode(
            KeyEvent {
                key,
                mods,
                repeat: event.repeat,
                press: event.press,
                unshifted: event.unshifted_text.chars().next(),
                physical: event.physical_text.chars().next(),
                text: if event.text.is_empty() { None } else { Some(event.text) },
                composing: event.composing,
            },
            config,
        )
    }

    /// Encodes a mouse event using whichever tracking/encoding modes the
    /// terminal currently has enabled. Empty when mouse reporting is off
    /// or the event can't be represented.
    pub fn encode_mouse(&self, event: FfiMouseEvent) -> Vec<u8> {
        use crate::modes::MouseTracking;
        use crate::mouse_encode::{
            encode, MouseAction, MouseButton, MouseEncoding, MouseEvent, MouseMods,
        };
        let terminal = lock_recover(&self.inner);
        let modes = terminal.modes();
        let action = match event.action {
            FfiMouseAction::Press => MouseAction::Press,
            FfiMouseAction::Release => MouseAction::Release,
            FfiMouseAction::Motion => MouseAction::Motion,
        };
        // Respect what the app asked for: no tracking means no bytes, and
        // plain "normal" tracking reports presses/releases only.
        match modes.mouse_tracking {
            MouseTracking::Off => return Vec::new(),
            MouseTracking::Normal if action == MouseAction::Motion => return Vec::new(),
            _ => {}
        }
        let button = match event.button {
            FfiMouseButton::Left => MouseButton::Left,
            FfiMouseButton::Middle => MouseButton::Middle,
            FfiMouseButton::Right => MouseButton::Right,
            FfiMouseButton::WheelUp => MouseButton::WheelUp,
            FfiMouseButton::WheelDown => MouseButton::WheelDown,
            FfiMouseButton::WheelLeft => MouseButton::WheelLeft,
            FfiMouseButton::WheelRight => MouseButton::WheelRight,
            FfiMouseButton::None => MouseButton::None,
        };
        let encoding = if modes.mouse_sgr {
            MouseEncoding::Sgr
        } else if modes.mouse_utf8 {
            MouseEncoding::Utf8
        } else {
            MouseEncoding::X10
        };
        encode(
            MouseEvent {
                button,
                action,
                mods: MouseMods {
                    shift: event.shift,
                    alt: event.alt,
                    ctrl: event.ctrl,
                },
                col: event.col,
                row: event.row,
            },
            encoding,
        )
        .unwrap_or_default()
    }

    /// Encodes pasted text, bracketing it when the app enabled DEC mode
    /// 2004 and always stripping the paste terminator.
    pub fn encode_paste(&self, text: String) -> Vec<u8> {
        let bracketed = lock_recover(&self.inner).modes().bracketed_paste;
        crate::paste::encode(&text, bracketed)
    }

    /// Whether pasting this text unbracketed would be risky (contains
    /// newlines or control characters) -- for a host-side confirmation.
    pub fn paste_is_unsafe(&self, text: String) -> bool {
        crate::paste::is_unsafe(&text)
    }

    /// Rows changed since the last call (viewport indices); clears the
    /// flags. A scroll or resize reports every row.
    pub fn take_damage(&self) -> Vec<u32> {
        let mut terminal = lock_recover(&self.inner);
        let rows = terminal.take_damage();
        // Damage is single-consumer. Whoever drains it here owns those rows;
        // the delta renderer must resync rather than miss them silently.
        lock_recover(&self.delta).foreign_drain = true;
        rows
    }

    /// Forces a full redraw on the next `takeDamage()`.
    pub fn mark_all_damaged(&self) {
        lock_recover(&self.inner).mark_all_damaged();
    }

    /// One call per frame: geometry, cursor, title, modes, viewport, the
    /// damaged row list, selection and graphics placements.
    pub fn snapshot(&self) -> FfiSnapshot {
        let mut terminal = lock_recover(&self.inner);
        let snapshot = snapshot_from_terminal(&mut terminal);
        lock_recover(&self.delta).foreign_drain = true;
        snapshot
    }

    /// Scrolls the viewport up into scrollback by `lines`.
    pub fn scroll_viewport_up(&self, lines: u32) {
        lock_recover(&self.inner).scroll_viewport_up(lines as usize);
    }

    /// Scrolls the viewport back down toward the live screen.
    pub fn scroll_viewport_down(&self, lines: u32) {
        lock_recover(&self.inner)
            .scroll_viewport_down(lines as usize);
    }

    /// Snaps the viewport back to the live screen.
    pub fn scroll_viewport_bottom(&self) {
        lock_recover(&self.inner).scroll_viewport_bottom();
    }

    /// Current viewport offset above the live screen, in lines.
    pub fn viewport_offset(&self) -> u32 {
        lock_recover(&self.inner).viewport_offset() as u32
    }

    /// Lines currently retained in scrollback.
    pub fn scrollback_len(&self) -> u32 {
        lock_recover(&self.inner).active_grid().scrollback_len() as u32
    }

    /// One viewport row as styled cells -- one call per row instead of
    /// `cols` calls to `get_cell`, and it reads through the scrollback
    /// offset set by `scroll_viewport_*`.
    pub fn viewport_row(&self, row: u32) -> Vec<FfiCell> {
        let terminal = lock_recover(&self.inner);
        let (dfg, dbg, _) = terminal.default_colors();
        let palette = terminal.palette();
        let grid = terminal.active_grid();
        terminal
            .viewport_row(row as usize)
            .iter()
            .map(|cell| {
                let uri = cell
                    .hyperlink
                    .and_then(|id| terminal.hyperlink_uri(id))
                    .map(str::to_string);
                cell_to_ffi(
                    cell,
                    uri,
                    grapheme_text(grid, cell),
                    palette,
                    dfg.unwrap_or(DEFAULT_FG),
                    dbg.unwrap_or(DEFAULT_BG),
                )
            })
            .collect()
    }

    /// The whole viewport as packed bytes: 16 per cell, rows top to bottom.
    ///
    /// Returning `Vec<FfiCell>` costs about seven microseconds per cell,
    /// because every field of every cell crosses the boundary as its own
    /// read. A full screen is tens of thousands of cells, so a frame spent
    /// something like eighty milliseconds just being handed over -- twelve
    /// frames a second before any drawing happened. One buffer of fixed
    /// records is a memcpy instead.
    ///
    /// Layout, little-endian, per cell:
    ///
    /// | offset | size | field |
    /// |---|---|---|
    /// | 0 | 4 | Unicode scalar, 0 for the tail of a wide pair |
    /// | 4 | 3 | foreground r, g, b |
    /// | 7 | 3 | background r, g, b |
    /// | 10 | 2 | attribute bits (see `PACKED_*` below) |
    /// | 12 | 1 | SGR 4:x underline style |
    /// | 13 | 3 | underline colour r, g, b |
    ///
    /// A cell holding more than one codepoint carries its first as the
    /// scalar and `PACKED_GRAPHEME` in its bits; `viewport_graphemes` (or a
    /// frame's `graphemes`) has the whole cluster.
    pub fn viewport_packed(&self) -> Vec<u8> {
        let terminal = lock_recover(&self.inner);
        viewport_packed_from_terminal(&terminal).0
    }

    /// The clusters of the cells `viewport_packed` marks `PACKED_GRAPHEME`.
    pub fn viewport_graphemes(&self) -> Vec<FfiGrapheme> {
        let terminal = lock_recover(&self.inner);
        viewport_packed_from_terminal(&terminal).1
    }

    /// Sets the host's grapheme-width-method: whether a grapheme cluster
    /// takes its presentation width (`Unicode`, upstream's default: an emoji
    /// sequence is two columns) or the sum of its codepoints' widths
    /// (`Legacy`). It is mode 2027's value now and after every reset; a
    /// program can still change the mode.
    pub fn set_grapheme_width_method(&self, method: FfiGraphemeWidthMethod) {
        lock_recover(&self.inner).set_grapheme_width_method(method.into());
    }

    /// Single call per frame: returns frame metadata, damaged rows, selection,
    /// graphics placements, and packed viewport cells captured under one terminal lock.
    ///
    /// Always carries the complete viewport, so this caller's *cells* can
    /// never go stale no matter who else is reading. Its `damaged_rows`
    /// hint is the one shared resource -- see `render_frame_delta` for the
    /// ownership rule.
    pub fn render_frame(&self) -> FfiRenderFrame {
        let mut engine = lock_recover(&self.inner);
        let epoch = engine.epoch;
        let snapshot = snapshot_from_terminal(&mut engine);
        let (packed_cells, graphemes) = viewport_packed_from_terminal(&engine);
        lock_recover(&self.delta).foreign_drain = true;
        FfiRenderFrame {
            snapshot,
            packed_cells,
            epoch,
            graphemes,
        }
    }

    /// `render_frame`, plus up to `rows_below` rows from beneath the viewport.
    ///
    /// A host translating the grid by a fraction of a cell uncovers a strip at
    /// the bottom edge. Without these rows that strip is background, and the
    /// motion reads as an exposed edge rather than as scrolling.
    ///
    /// The rows come from the same accessor as the viewport itself, one index
    /// past its last row: scrolled back, that is the next real line; at the
    /// tail there is nothing below the screen and the rows come back blank,
    /// which is exactly what should be drawn there.
    ///
    /// `rows_below` is clamped to `MAX_OVERSCAN_ROWS` -- a fractional offset is
    /// under one cell by construction, so one row always suffices, and the
    /// clamp keeps a wrong argument from allocating an unbounded frame.
    pub fn render_frame_overscan(&self, rows_below: u32) -> FfiRenderFrameOverscan {
        let mut terminal = lock_recover(&self.inner);
        let epoch = terminal.epoch;
        let snapshot = snapshot_from_terminal(&mut terminal);
        let overscan_rows = rows_below.min(MAX_OVERSCAN_ROWS);
        let rows = terminal.active_grid().rows() as u32;
        let indices: Vec<u32> = (0..rows.saturating_add(overscan_rows)).collect();
        let (packed_cells, graphemes) = packed_rows_from_terminal(&terminal, &indices);
        lock_recover(&self.delta).foreign_drain = true;
        FfiRenderFrameOverscan {
            snapshot,
            packed_cells,
            overscan_rows,
            epoch,
            graphemes,
        }
    }

    /// One frame for a host that keeps its own row cache: the same metadata
    /// `render_frame` returns, but only the rows that actually changed --
    /// or the whole viewport when a delta would be wrong or pointless.
    ///
    /// A full 100x50 frame is 80'000 bytes over the boundary every time the
    /// cursor blinks; one changed row is 1'600. That difference is the
    /// entire point of this call.
    ///
    /// Pass the `frame_version` of the last payload you successfully
    /// applied, or 0 if you have none. The reply's `frame_version` is what
    /// you pass next time.
    ///
    /// # Damage ownership
    ///
    /// The terminal's damage is a single-consumer resource: reading it
    /// clears it (`Terminal::take_damage`), so two readers cannot both see
    /// the same dirty rows. This API does not pretend otherwise -- it makes
    /// the conflict *loud* instead:
    ///
    /// * `render_frame` / `snapshot` / `take_damage` still drain damage as
    ///   they always did, and each records that it did. The next delta then
    ///   comes back as a full resync with `DamageOwnershipLost`, so a delta
    ///   consumer that shares a core with a full-frame renderer repaints
    ///   redundantly -- never wrongly.
    /// * A delta consumer that misses a frame presents a `since_version`
    ///   that is not the one we handed out and gets `VersionMismatch`, so a
    ///   second delta renderer on one core degrades to full frames rather
    ///   than silently diverging.
    /// * `render_frame`'s cells are unaffected either way: it always packs
    ///   the entire viewport. Only its `damaged_rows` hint can be emptied
    ///   by a delta call, which is why a full-frame caller must treat that
    ///   list as advisory once a delta consumer exists.
    ///
    /// The supported arrangement is one damage consumer per core. The
    /// checks above exist so that violating it is expensive, not silent.
    pub fn render_frame_delta(&self, since_version: u64) -> FfiRenderFrameDelta {
        let mut terminal = lock_recover(&self.inner);
        let mut state = lock_recover(&self.delta);

        // Drains damage: this call is the damage consumer for its frame.
        let mut snapshot = snapshot_from_terminal(&mut terminal);
        let cols = snapshot.cols;
        let rows = snapshot.rows;
        let viewport_offset = snapshot.viewport_offset;
        let alternate = terminal.active_screen() == ScreenBuffer::Alternate;

        // Most specific cause first, so the reason a host is told explains
        // what actually happened rather than a symptom of it.
        let reason = if !state.started {
            FfiResyncReason::FirstFrame
        } else if state.reset_pending {
            FfiResyncReason::Reset
        } else if since_version != state.version {
            FfiResyncReason::VersionMismatch
        } else if state.foreign_drain {
            FfiResyncReason::DamageOwnershipLost
        } else if cols != state.cols || rows != state.rows {
            FfiResyncReason::Resized
        } else if viewport_offset != state.viewport_offset {
            FfiResyncReason::ViewportScrolled
        } else if alternate != state.alternate {
            FfiResyncReason::ScreenSwitched
        } else if rows > 0 && snapshot.damaged_rows.len() as u32 >= rows {
            FfiResyncReason::FullDamage
        } else {
            FfiResyncReason::Delta
        };
        let full_resync = reason != FfiResyncReason::Delta;

        let row_indices: Vec<u32> = if full_resync {
            (0..rows).collect()
        } else {
            snapshot.damaged_rows.clone()
        };
        let (packed_cells, graphemes) = packed_rows_from_terminal(&terminal, &row_indices);

        // The snapshot's row list and the payload's are the same list.
        snapshot.damaged_rows = row_indices.clone();
        let row_ranges = collapse_row_ranges(&row_indices);

        let base_version = if full_resync { 0 } else { state.version };
        let frame_version = state.version + 1;

        state.version = frame_version;
        state.started = true;
        state.cols = cols;
        state.rows = rows;
        state.viewport_offset = viewport_offset;
        state.alternate = alternate;
        state.reset_pending = false;
        state.foreign_drain = false;

        FfiRenderFrameDelta {
            snapshot,
            frame_version,
            base_version,
            full_resync,
            resync_reason: reason,
            cols,
            rows,
            cell_stride: PACKED_CELL_SIZE as u32,
            row_stride: cols * PACKED_CELL_SIZE as u32,
            row_indices,
            row_ranges,
            packed_cells,
            graphemes,
        }
    }

    /// What the running program asked of Shift with XTSHIFTESCAPE (`CSI > Ps
    /// s`): `true` to have it reported with mouse events, `false` to leave it
    /// to the terminal's selection, `None` if it has not asked. The host's
    /// `mouse-shift-capture` decides whether the request counts.
    pub fn mouse_shift_capture(&self) -> Option<bool> {
        lock_recover(&self.inner).modes().shift_capture
    }

    /// Whether the cursor sits on an OSC 133 prompt row (for prompt-jump
    /// and click-to-move features in the host app).
    pub fn cursor_is_at_prompt(&self) -> bool {
        lock_recover(&self.inner).cursor_is_at_prompt()
    }

    /// The OSC 133 semantic mark of `row`: 0 unset, 1 prompt,
    /// 2 prompt continuation.
    pub fn row_semantic_prompt(&self, row: u32) -> u8 {
        use crate::grid::SemanticPrompt;
        match lock_recover(&self.inner)
            .active_grid()
            .row_semantic_prompt(row as usize)
        {
            SemanticPrompt::Unset => 0,
            SemanticPrompt::Prompt => 1,
            SemanticPrompt::PromptContinuation => 2,
        }
    }

    /// The cursor's current visual style (DECSCUSR).
    pub fn cursor_style(&self) -> FfiCursorStyle {
        lock_recover(&self.inner).cursor_style().into()
    }

    /// Resizes the active/alternate grids.
    pub fn resize(&self, cols: u32, rows: u32) {
        lock_recover(&self.inner)
            .resize(cols as usize, rows as usize);
    }

    pub fn cursor_row(&self) -> u32 {
        lock_recover(&self.inner).cursor().0 as u32
    }

    pub fn cursor_col(&self) -> u32 {
        lock_recover(&self.inner).cursor().1 as u32
    }

    pub fn cursor_visible(&self) -> bool {
        lock_recover(&self.inner).cursor_visible()
    }

    pub fn title(&self) -> String {
        lock_recover(&self.inner).title().to_string()
    }

    pub fn cols(&self) -> u32 {
        lock_recover(&self.inner).active_grid().cols() as u32
    }

    pub fn rows(&self) -> u32 {
        lock_recover(&self.inner).active_grid().rows() as u32
    }

    /// Returns the styled cell at (row, col) in the currently active grid,
    /// or `None` if out of bounds.
    pub fn get_cell(&self, row: u32, col: u32) -> Option<FfiCell> {
        let terminal = lock_recover(&self.inner);
        let grid = terminal.active_grid();
        grid.get(row as usize, col as usize).map(|cell| {
            let hyperlink_uri = cell
                .hyperlink
                .and_then(|id| terminal.hyperlink_uri(id))
                .map(str::to_string);
            let (dfg, dbg, _) = terminal.default_colors();
            cell_to_ffi(
                cell,
                hyperlink_uri,
                grapheme_text(grid, cell),
                terminal.palette(),
                dfg.unwrap_or(DEFAULT_FG),
                dbg.unwrap_or(DEFAULT_BG),
            )
        })
    }

    /// Returns the plain-text characters of one row of the active grid
    /// (no color/attrs) -- convenient for quick text extraction/debugging.
    pub fn get_line(&self, row: u32) -> String {
        let terminal = lock_recover(&self.inner);
        let grid = terminal.active_grid();
        let row = row as usize;
        if row >= grid.rows() {
            return String::new();
        }
        let mut line = String::with_capacity(grid.cols());
        for col in 0..grid.cols() {
            match grid.get(row, col) {
                Some(cell) => {
                    line.push(cell.char);
                    line.push_str(grid.grapheme(cell));
                }
                None => line.push(' '),
            }
        }
        line
    }

    /// Begins a new selection at `(row, col)` in the given mode.
    pub fn start_selection(&self, row: u32, col: u32, mode: FfiSelectionMode) {
        lock_recover(&self.inner)
            .start_selection(row as usize, col as usize, mode.into());
    }

    /// Updates the drag endpoint of the current selection. No-op if no
    /// selection has been started.
    pub fn extend_selection(&self, row: u32, col: u32) {
        lock_recover(&self.inner)
            .extend_selection(row as usize, col as usize);
    }

    /// Selects the word under `(row, col)`, as a double-click does. A run
    /// continues across a soft wrap, so a path or URL broken by the screen
    /// edge still selects whole.
    pub fn select_word(&self, row: u32, col: u32) {
        lock_recover(&self.inner)
            .select_word(row as usize, col as usize);
    }

    /// Selects the whole logical line under `(row, col)`, as a triple-click
    /// does, following soft wraps in both directions.
    pub fn select_line(&self, row: u32, col: u32) {
        lock_recover(&self.inner)
            .select_line(row as usize, col as usize);
    }

    /// Discards the current selection, if any.
    pub fn clear_selection(&self) {
        lock_recover(&self.inner).clear_selection();
    }

    /// Whether a selection is currently active.
    pub fn has_selection(&self) -> bool {
        lock_recover(&self.inner).has_selection()
    }

    /// The normalized bounds of the current selection, for highlighting.
    /// Returns `None` if there's no active selection.
    pub fn selection_range(&self) -> Option<FfiSelectionRange> {
        let term = lock_recover(&self.inner);
        let mode = term.selection_mode().into();
        let ((start_row, start_col), (end_row, end_col)) = term.selection_range()?;
        Some(FfiSelectionRange {
            start_row: start_row as u32,
            start_col: start_col as u32,
            end_row: end_row as u32,
            end_col: end_col as u32,
            mode,
        })
    }

    /// The plain text covered by the current selection, or `None` if
    /// there's no active selection.
    pub fn selected_text(&self) -> Option<String> {
        lock_recover(&self.inner).selected_text()
    }

    /// Sets the host's base theme: default foreground/background/cursor
    /// colors and indexed palette entries, applied underneath whatever a
    /// running program has set via OSC 4/10/11/12.
    ///
    /// Base colors are what OSC 104 (all or by index), OSC 110/111/112, and
    /// a full reset (RIS, `ESC c`) restore to, instead of the engine's
    /// built-in defaults -- and what OSC 4/10/11/12 queries report until a
    /// program overrides them. Calling this while a session is already
    /// running immediately updates any live color a program hasn't
    /// explicitly overridden, so a theme change takes effect without
    /// clobbering a program's own color choices. `foreground`, `background`,
    /// and `cursor` of `None` revert that slot to unconfigured (the engine's
    /// built-in default). `palette` only touches the listed indices; indices
    /// not listed keep whatever base they already had (the built-in default
    /// if never set).
    pub fn set_base_colors(
        &self,
        foreground: Option<FfiRgb>,
        background: Option<FfiRgb>,
        cursor: Option<FfiRgb>,
        palette: Vec<FfiPaletteEntry>,
    ) {
        let mut term = lock_recover(&self.inner);
        let entries: Vec<(u8, (u8, u8, u8))> = palette
            .into_iter()
            .map(|entry| (entry.index, entry.color.into()))
            .collect();
        term.terminal.set_base_colors(
            foreground.map(Into::into),
            background.map(Into::into),
            cursor.map(Into::into),
            &entries,
        );
        // Cells resolve `Color::Default`/`Indexed` at render time rather
        // than storing RGB, so a base-color change needs an explicit
        // damage mark -- unlike a content edit, it doesn't touch any cell.
        term.terminal.mark_all_damaged();
    }

    /// Sets the host's cursor style: what a program's DECSCUSR 0 and a reset
    /// return to. It applies at once unless a program has chosen a style.
    pub fn set_default_cursor_style(&self, shape: FfiCursorShape, blinking: bool) {
        let mut term = lock_recover(&self.inner);
        term.terminal.set_default_cursor_style(crate::cursor_style::CursorStyle {
            shape: shape.into(),
            blinking,
        });
    }

    /// Sets how many lines of history the terminal keeps; 0 keeps none.
    /// Shrinking it drops the oldest lines.
    pub fn set_scrollback_limit(&self, lines: u32) {
        let mut term = lock_recover(&self.inner);
        term.terminal.set_scrollback_capacity(lines as usize);
    }

    /// Resets the terminal state completely, except the base colors from
    /// `set_base_colors`: those are the host's theme, not terminal state.
    pub fn reset(&self) {
        let mut term = lock_recover(&self.inner);
        term.terminal = term.terminal.fresh_keeping_host_config();
        // Replacing the engine is exactly what the epoch counts, whichever
        // call did it: anything captured against the old one is now stale.
        term.epoch = term.epoch.wrapping_add(1);
        // The grid is a different object now; its dirty flags say nothing
        // about what the delta consumer still has on screen.
        lock_recover(&self.delta).reset_pending = true;
    }

    /// Scrolls to a specific viewport offset (lines scrolled into scrollback).
    pub fn scroll_to(&self, offset: u32) {
        let mut term = lock_recover(&self.inner);
        term.scroll_viewport_bottom();
        if offset > 0 {
            term.scroll_viewport_up(offset as usize);
        }
    }

    /// Everything the terminal holds as plain text: retained scrollback
    /// first, then the live screen, with soft wraps rejoined.
    ///
    /// This is what a host copies. `get_plain_text` below is viewport-shaped
    /// and cannot see history, so using it for a copy silently returns the
    /// last screenful of a session that has thousands of lines.
    pub fn buffer_text(&self) -> String {
        lock_recover(&self.inner).buffer_text()
    }

    /// Where the viewport sits as a fraction: 0 is the oldest retained line,
    /// 1 is the live screen. A detachable surface stores this across teardown
    /// -- a line number would not survive scrollback eviction.
    pub fn scroll_position(&self) -> f64 {
        lock_recover(&self.inner).scroll_position()
    }

    /// Restores a fraction from `scroll_position`. Out-of-range values are
    /// clamped, because the caller is usually replaying a stored number.
    pub fn set_scroll_position(&self, position: f64) {
        lock_recover(&self.inner).set_scroll_position(position);
    }

    /// Returns bounded plain text from start_row for up to max_rows lines.
    pub fn get_plain_text(&self, start_row: u32, max_rows: u32) -> String {
        let terminal = lock_recover(&self.inner);
        let rows = terminal.active_grid().rows();
        if start_row as usize >= rows {
            return String::new();
        }
        let end_row = (start_row as usize + max_rows as usize).min(rows);
        let grid = terminal.active_grid();
        let mut lines = Vec::new();
        let mut current = String::new();
        for r in (start_row as usize)..end_row {
            for cell in terminal.viewport_row(r) {
                if cell.is_wide_spacer || cell.is_wide_spacer_head {
                    continue;
                }
                grid.push_cell_text(&mut current, &cell);
            }
            if r + 1 == end_row || !terminal.viewport_line_wrapped(r + 1) {
                while current.ends_with(' ') {
                    current.pop();
                }
                lines.push(std::mem::take(&mut current));
            }
        }
        if !current.is_empty() {
            while current.ends_with(' ') {
                current.pop();
            }
            lines.push(current);
        }
        while lines.last().is_some_and(|l| l.is_empty()) {
            lines.pop();
        }
        lines.join("\n")
    }
}

fn snapshot_from_terminal(terminal: &mut Terminal) -> FfiSnapshot {
    let damaged_rows = terminal.take_damage();
    let (cursor_row, cursor_col) = terminal.cursor();
    let m = terminal.modes();
    let modes = FfiTerminalModes {
        autowrap: m.autowrap,
        origin_mode: m.origin_mode,
        cursor_key_app_mode: m.cursor_key_app_mode,
        mouse_tracking: m.mouse_tracking.into(),
        mouse_utf8: m.mouse_utf8,
        mouse_sgr: m.mouse_sgr,
        focus_events: m.focus_events,
        bracketed_paste: m.bracketed_paste,
        alternate_screen: terminal.active_screen() == ScreenBuffer::Alternate,
        alternate_scroll: m.alternate_scroll,
    };
    let selection_mode = terminal.selection_mode().into();
    let selection = terminal.selection_range().map(|((sr, sc), (er, ec))| FfiSelectionRange {
        start_row: sr as u32,
        start_col: sc as u32,
        end_row: er as u32,
        end_col: ec as u32,
        mode: selection_mode,
    });
    let graphics_placements = terminal
        .graphics_placements()
        .iter()
        .map(|p| FfiGraphicsPlacement {
            image_id: p.image_id,
            placement_id: p.placement_id,
            row: p.row as u32,
            col: p.col as u32,
        })
        .collect();
    FfiSnapshot {
        cols: terminal.active_grid().cols() as u32,
        rows: terminal.active_grid().rows() as u32,
        cursor_row: cursor_row as u32,
        cursor_col: cursor_col as u32,
        cursor_visible: terminal.cursor_visible(),
        cursor_style: terminal.cursor_style().into(),
        title: terminal.title().to_string(),
        modes,
        viewport_offset: terminal.viewport_offset() as u32,
        scrollback_len: terminal.active_grid().scrollback_len() as u32,
        damaged_rows,
        selection,
        graphics_placements,
    }
}

fn viewport_packed_from_terminal(terminal: &Terminal) -> (Vec<u8>, Vec<FfiGrapheme>) {
    let rows = terminal.active_grid().rows() as u32;
    let all: Vec<u32> = (0..rows).collect();
    packed_rows_from_terminal(terminal, &all)
}

/// Packs the given viewport rows, in the order given, into the wire layout
/// documented on `viewport_packed`: each row is exactly
/// `cols * PACKED_CELL_SIZE` bytes and they follow one another with no
/// header, so the caller indexes a row by its position in `rows` -- not by
/// its screen position, which is what `row_indices` is for.
///
/// Out-of-range indices cannot happen from inside this module (the callers
/// derive them from the grid), and `viewport_row` fills short rows with
/// blanks anyway, so the packed size is a function of `rows.len()` alone.
///
/// Multi-codepoint clusters travel beside the bytes, so the layout and its
/// size stay as they were.
fn packed_rows_from_terminal(terminal: &Terminal, rows: &[u32]) -> (Vec<u8>, Vec<FfiGrapheme>) {
    let (dfg, dbg, _) = terminal.default_colors();
    let default_fg = dfg.unwrap_or(DEFAULT_FG);
    let default_bg = dbg.unwrap_or(DEFAULT_BG);
    let palette = terminal.palette();
    let grid = terminal.active_grid();
    let cols = grid.cols();

    let mut out = Vec::with_capacity(rows.len() * cols * PACKED_CELL_SIZE);
    let mut graphemes = Vec::new();
    for (index, &row) in rows.iter().enumerate() {
        for (col, cell) in terminal.viewport_row(row as usize).into_iter().enumerate() {
            let grapheme = grapheme_text(grid, &cell);
            let ch = if cell.is_wide_spacer {
                0
            } else if cell.char == '\0' {
                u32::from(' ')
            } else {
                u32::from(cell.char)
            };
            let (fr, fg, fb) = resolve_color(cell.fg, default_fg, palette);
            let (br, bg, bb) = resolve_color(cell.bg, default_bg, palette);
            let (ur, ug, ub) = resolve_color(cell.underline_color, (fr, fg, fb), palette);

            let mut bits: u16 = 0;
            let mut set = |flag: u16, on: bool| {
                if on {
                    bits |= flag;
                }
            };
            set(PACKED_BOLD, cell.attrs.contains(CellAttrs::BOLD));
            set(PACKED_DIM, cell.attrs.contains(CellAttrs::DIM));
            set(PACKED_ITALIC, cell.attrs.contains(CellAttrs::ITALIC));
            set(PACKED_UNDERLINE, cell.attrs.contains(CellAttrs::UNDERLINE));
            set(PACKED_BLINK, cell.attrs.contains(CellAttrs::BLINK));
            set(PACKED_REVERSE, cell.attrs.contains(CellAttrs::REVERSE));
            set(PACKED_HIDDEN, cell.attrs.contains(CellAttrs::HIDDEN));
            set(PACKED_STRIKETHROUGH, cell.attrs.contains(CellAttrs::STRIKETHROUGH));
            set(PACKED_OVERLINE, cell.attrs.contains(CellAttrs::OVERLINE));
            set(PACKED_WIDE, cell.is_wide_spacer_head);
            set(PACKED_GRAPHEME, grapheme.is_some());
            if let Some(text) = grapheme {
                graphemes.push(FfiGrapheme {
                    row: index as u32,
                    col: col as u32,
                    text,
                });
            }

            out.extend_from_slice(&ch.to_le_bytes());
            out.extend_from_slice(&[fr, fg, fb, br, bg, bb]);
            out.extend_from_slice(&bits.to_le_bytes());
            out.push(cell.underline_style);
            out.extend_from_slice(&[ur, ug, ub]);
        }
    }
    (out, graphemes)
}

/// Collapses an ascending row list into contiguous runs. `[0,1,2,7,8]`
/// becomes two ranges; a host uploading textures cares about runs, not
/// individual rows.
fn collapse_row_ranges(rows: &[u32]) -> Vec<FfiRowRange> {
    let mut ranges: Vec<FfiRowRange> = Vec::new();
    for &row in rows {
        match ranges.last_mut() {
            Some(last) if last.start + last.count == row => last.count += 1,
            _ => ranges.push(FfiRowRange { start: row, count: 1 }),
        }
    }
    ranges
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `lock_recover` must not panic on a healthy mutex, and must return the
    /// data untouched.
    #[test]
    fn lock_recover_locks_a_healthy_mutex() {
        let mutex = Mutex::new(5);
        assert_eq!(*lock_recover(&mutex), 5);
    }

    /// Poisoning leaves the data exactly as the panicking thread last left
    /// it -- a `Mutex` only ever unlocks by dropping the guard, so nothing
    /// is left half-written -- and `lock_recover` must hand it back instead
    /// of panicking the way `.lock().unwrap()` would.
    #[test]
    fn lock_recover_survives_a_poisoned_mutex() {
        let mutex = Mutex::new(1);
        let prev_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            let mut guard = mutex.lock().unwrap();
            *guard = 2;
            panic!("simulated engine bug while holding the lock");
        }));
        std::panic::set_hook(prev_hook);
        assert!(result.is_err());
        assert!(mutex.is_poisoned());

        let mut guard = lock_recover(&mutex);
        assert_eq!(*guard, 2, "the poisoned guard must carry the last write, not be reset");
        *guard = 3;
        drop(guard);
        assert_eq!(*lock_recover(&mutex), 3);
    }

    /// The scenario `lock_recover` exists for: an engine bug panics while
    /// some call holds `TakoCore::inner`, poisoning it, and every ordinary
    /// call after that must keep working -- which is what a plain
    /// `.lock().unwrap()` would not do, since a poisoned mutex panics on
    /// every subsequent lock for the rest of the process's life, and Swift
    /// only ever sees one `TakoCore` per session.
    #[test]
    fn takocore_keeps_working_after_its_engine_mutex_is_poisoned() {
        let core = std::sync::Arc::new(TakoCore::new(20, 5));
        core.feed(b"before poison".to_vec());

        let poisoner = std::sync::Arc::clone(&core);
        let prev_hook = std::panic::take_hook();
        std::panic::set_hook(Box::new(|_| {}));
        let handle = std::thread::spawn(move || {
            let _guard = poisoner.inner.lock().unwrap();
            panic!("simulated engine bug while holding the terminal lock");
        });
        let _ = handle.join();
        std::panic::set_hook(prev_hook);

        assert!(core.inner.is_poisoned());

        // Ordinary calls keep working: feed, render, and read state back
        // out correctly, exactly as if nothing had panicked.
        core.feed(b"\r\nafter poison".to_vec());
        assert_eq!(core.get_line(0).trim_end_matches(['\0', ' ']), "before poison");
        assert_eq!(core.get_line(1).trim_end_matches(['\0', ' ']), "after poison");

        let frame = core.render_frame();
        assert_eq!(frame.snapshot.cols, 20);
        assert_eq!(frame.snapshot.rows, 5);
        assert_eq!(frame.packed_cells.len(), 20 * 5 * PACKED_CELL_SIZE);

        assert_eq!(core.cursor_row(), 1);
    }

    /// Applies a delta the way a host renderer would: a full resync
    /// replaces the row cache, a delta patches the named rows in place.
    /// Every structural invariant the record promises is checked here, so
    /// each test that hydrates also re-checks them.
    fn hydrate(cache: &mut Vec<u8>, delta: &FfiRenderFrameDelta) {
        let stride = delta.row_stride as usize;
        assert_eq!(delta.cell_stride as usize, PACKED_CELL_SIZE);
        assert_eq!(stride, delta.cols as usize * PACKED_CELL_SIZE);
        assert_eq!(
            delta.packed_cells.len(),
            delta.row_indices.len() * stride,
            "packed payload must be exactly the rows it names"
        );
        assert_eq!(
            delta.row_indices, delta.snapshot.damaged_rows,
            "the record must not disagree with its own snapshot"
        );
        assert_eq!(
            delta.row_indices,
            delta
                .row_ranges
                .iter()
                .flat_map(|r| r.start..r.start + r.count)
                .collect::<Vec<u32>>(),
            "ranges must expand back to the row list"
        );
        assert!(delta.row_indices.iter().all(|&r| r < delta.rows));

        if delta.full_resync {
            assert_eq!(delta.row_indices, (0..delta.rows).collect::<Vec<u32>>());
            assert_eq!(delta.base_version, 0);
            assert_ne!(delta.resync_reason, FfiResyncReason::Delta);
            *cache = delta.packed_cells.clone();
            return;
        }

        assert_eq!(delta.resync_reason, FfiResyncReason::Delta);
        assert_eq!(cache.len(), delta.rows as usize * stride);
        for (slot, &row) in delta.row_indices.iter().enumerate() {
            let src = &delta.packed_cells[slot * stride..(slot + 1) * stride];
            let dst = row as usize * stride;
            cache[dst..dst + stride].copy_from_slice(src);
        }
    }

    #[test]
    fn test_render_frame_delta_first_frame_is_the_full_reference() {
        let core = TakoCore::new(20, 6);
        core.feed(b"first\r\nsecond".to_vec());

        let delta = core.render_frame_delta(0);

        assert!(delta.full_resync);
        assert_eq!(delta.resync_reason, FfiResyncReason::FirstFrame);
        assert_eq!(delta.frame_version, 1, "versions start at 1, never 0");
        assert_eq!(delta.base_version, 0);
        assert_eq!(delta.cols, 20);
        assert_eq!(delta.rows, 6);
        assert_eq!(delta.row_ranges, vec![FfiRowRange { start: 0, count: 6 }]);

        let mut cache = Vec::new();
        hydrate(&mut cache, &delta);
        // The full payload IS the full reference, byte for byte.
        assert_eq!(cache, core.viewport_packed());
        assert_eq!(cache.len(), 20 * 6 * PACKED_CELL_SIZE);
    }

    #[test]
    fn test_render_frame_delta_one_and_two_row_changes_hydrate_to_reference() {
        let core = TakoCore::new(20, 6);
        core.feed(b"alpha\r\nbravo\r\ncharlie".to_vec());

        let first = core.render_frame_delta(0);
        let mut cache = Vec::new();
        hydrate(&mut cache, &first);
        assert_eq!(cache, core.viewport_packed());

        // One row changes.
        core.feed(b"\x1b[2;1Hdelta!".to_vec());
        let one = core.render_frame_delta(first.frame_version);
        assert!(!one.full_resync, "one changed row must not resync");
        assert_eq!(one.base_version, first.frame_version);
        assert_eq!(one.frame_version, first.frame_version + 1);
        assert!(one.row_indices.contains(&1));
        assert!(
            one.row_indices.len() < one.rows as usize,
            "a one-row edit must not repack the viewport: {:?}",
            one.row_indices
        );
        hydrate(&mut cache, &one);
        assert_eq!(cache, core.viewport_packed(), "one-row delta must hydrate to the next full reference");

        // Two rows change, non-adjacent, so the ranges do not merge.
        core.feed(b"\x1b[1;1Hone\x1b[5;1Hfive".to_vec());
        let two = core.render_frame_delta(one.frame_version);
        assert!(!two.full_resync);
        assert!(two.row_indices.contains(&0) && two.row_indices.contains(&4));
        assert!(two.row_indices.len() < two.rows as usize);
        assert!(two.row_ranges.len() >= 2, "0 and 4 cannot be one run");
        hydrate(&mut cache, &two);
        assert_eq!(cache, core.viewport_packed(), "two-row delta must hydrate to the next full reference");

        // Nothing changed at all: still a valid, empty delta.
        let idle = core.render_frame_delta(two.frame_version);
        assert!(!idle.full_resync);
        assert!(idle.row_indices.is_empty());
        assert!(idle.packed_cells.is_empty());
        hydrate(&mut cache, &idle);
        assert_eq!(cache, core.viewport_packed());
    }

    #[test]
    fn test_render_frame_delta_empty_delta_still_carries_metadata() {
        let core = TakoCore::new(20, 6);
        core.feed(b"content".to_vec());
        let first = core.render_frame_delta(0);

        // Title, modes, cursor visibility and selection: host-visible state
        // that moves without a single cell going dirty.
        core.feed(b"\x1b]0;New Title\x07\x1b[?7l\x1b[?25l".to_vec());
        core.start_selection(1, 2, FfiSelectionMode::Linear);
        core.extend_selection(2, 5);

        let delta = core.render_frame_delta(first.frame_version);

        assert!(delta.row_indices.is_empty(), "no cell changed");
        assert!(delta.packed_cells.is_empty(), "no cell changed, no bytes");
        assert!(!delta.full_resync);
        assert_eq!(delta.frame_version, first.frame_version + 1);
        assert_eq!(delta.snapshot.title, "New Title");
        assert!(!delta.snapshot.modes.autowrap);
        assert!(!delta.snapshot.cursor_visible);
        let selection = delta.snapshot.selection.expect("selection must be reported");
        assert_eq!((selection.start_row, selection.start_col), (1, 2));
        assert_eq!((selection.end_row, selection.end_col), (2, 5));
    }

    #[test]
    fn test_render_frame_delta_resize_forces_resync() {
        let core = TakoCore::new(20, 6);
        core.feed(b"before resize".to_vec());
        let first = core.render_frame_delta(0);

        core.resize(30, 8);
        let delta = core.render_frame_delta(first.frame_version);

        assert!(delta.full_resync);
        assert_eq!(delta.resync_reason, FfiResyncReason::Resized);
        assert_eq!((delta.cols, delta.rows), (30, 8));
        assert_eq!(delta.row_stride, 30 * PACKED_CELL_SIZE as u32);

        let mut cache = Vec::new();
        hydrate(&mut cache, &delta);
        assert_eq!(cache, core.viewport_packed());
    }

    #[test]
    fn test_render_frame_delta_viewport_scroll_forces_resync() {
        let core = TakoCore::new(20, 4);
        for line in 0..12 {
            core.feed(format!("line {line}\r\n").into_bytes());
        }
        let first = core.render_frame_delta(0);
        assert_eq!(first.snapshot.viewport_offset, 0);

        core.scroll_viewport_up(2);
        let scrolled = core.render_frame_delta(first.frame_version);

        assert!(scrolled.full_resync, "every row index moved");
        assert_eq!(scrolled.resync_reason, FfiResyncReason::ViewportScrolled);
        assert_eq!(scrolled.snapshot.viewport_offset, 2);
        let mut cache = Vec::new();
        hydrate(&mut cache, &scrolled);
        assert_eq!(cache, core.viewport_packed());

        // Scrolling back is equally a resync.
        core.scroll_viewport_bottom();
        let back = core.render_frame_delta(scrolled.frame_version);
        assert!(back.full_resync);
        assert_eq!(back.resync_reason, FfiResyncReason::ViewportScrolled);
        hydrate(&mut cache, &back);
        assert_eq!(cache, core.viewport_packed());
    }

    #[test]
    fn test_render_frame_delta_reset_forces_resync() {
        let core = TakoCore::new(20, 6);
        core.feed(b"stuff on screen".to_vec());
        let first = core.render_frame_delta(0);

        core.reset();
        let delta = core.render_frame_delta(first.frame_version);

        assert!(delta.full_resync);
        assert_eq!(delta.resync_reason, FfiResyncReason::Reset);
        let mut cache = Vec::new();
        hydrate(&mut cache, &delta);
        assert_eq!(cache, core.viewport_packed());

        // And the next frame is an ordinary delta again.
        core.feed(b"fresh".to_vec());
        let after = core.render_frame_delta(delta.frame_version);
        assert!(!after.full_resync);
        hydrate(&mut cache, &after);
        assert_eq!(cache, core.viewport_packed());
    }

    #[test]
    fn test_render_frame_delta_alternate_screen_switch_forces_resync() {
        let core = TakoCore::new(20, 6);
        core.feed(b"primary text".to_vec());
        let first = core.render_frame_delta(0);

        core.feed(b"\x1b[?1049h".to_vec()); // enter alternate screen
        let entered = core.render_frame_delta(first.frame_version);
        assert!(entered.full_resync);
        assert_eq!(entered.resync_reason, FfiResyncReason::ScreenSwitched);
        let mut cache = Vec::new();
        hydrate(&mut cache, &entered);
        assert_eq!(cache, core.viewport_packed());

        core.feed(b"\x1b[?1049l".to_vec()); // back to primary
        let left = core.render_frame_delta(entered.frame_version);
        assert!(left.full_resync, "a different grid entirely");
        assert_eq!(left.resync_reason, FfiResyncReason::ScreenSwitched);
        hydrate(&mut cache, &left);
        assert_eq!(cache, core.viewport_packed());
    }

    #[test]
    fn test_render_frame_delta_full_damage_is_a_resync_not_a_row_list() {
        let core = TakoCore::new(20, 6);
        core.feed(b"content".to_vec());
        let first = core.render_frame_delta(0);

        // Cache-invalidation equivalent: host raised a window, changed font.
        core.mark_all_damaged();
        let delta = core.render_frame_delta(first.frame_version);

        assert!(delta.full_resync);
        assert_eq!(delta.resync_reason, FfiResyncReason::FullDamage);
        assert_eq!(delta.row_ranges, vec![FfiRowRange { start: 0, count: 6 }]);
        let mut cache = Vec::new();
        hydrate(&mut cache, &delta);
        assert_eq!(cache, core.viewport_packed());
    }

    #[test]
    fn test_render_frame_delta_stale_version_is_detectable() {
        let core = TakoCore::new(20, 6);
        core.feed(b"one".to_vec());
        let first = core.render_frame_delta(0);
        core.feed(b"\r\ntwo".to_vec());
        let second = core.render_frame_delta(first.frame_version);
        assert!(!second.full_resync);

        // A renderer that missed `second` replays an old version: it is told
        // so, and handed a complete frame instead of a wrong patch.
        core.feed(b"\r\nthree".to_vec());
        let stale = core.render_frame_delta(first.frame_version);
        assert!(stale.full_resync);
        assert_eq!(stale.resync_reason, FfiResyncReason::VersionMismatch);
        let mut cache = Vec::new();
        hydrate(&mut cache, &stale);
        assert_eq!(cache, core.viewport_packed());

        // Versions are strictly monotonic across all of it.
        assert!(first.frame_version < second.frame_version);
        assert!(second.frame_version < stale.frame_version);

        // A caller that "already applied" a version we never issued is stale
        // too -- there is no such frame to patch on top of.
        core.feed(b"\r\nfour".to_vec());
        let from_future = core.render_frame_delta(stale.frame_version + 99);
        assert!(from_future.full_resync);
        assert_eq!(from_future.resync_reason, FfiResyncReason::VersionMismatch);
    }

    /// The damage flags are single-consumer: whoever reads them clears them.
    /// This encodes the ownership rule that falls out of that -- a second
    /// consumer makes the delta renderer resync, and never makes either one
    /// silently stale.
    #[test]
    fn test_render_frame_delta_damage_ownership_never_leaves_a_reader_stale() {
        let core = TakoCore::new(20, 6);
        core.feed(b"shared core".to_vec());
        let first = core.render_frame_delta(0);
        let mut cache = Vec::new();
        hydrate(&mut cache, &first);

        // A full-frame renderer drains the damage the delta consumer needs.
        core.feed(b"\x1b[3;1Hsecond renderer".to_vec());
        let frame = core.render_frame();
        assert!(frame.snapshot.damaged_rows.contains(&2));
        // The full-frame caller is never stale: it always carries every cell.
        assert_eq!(frame.packed_cells, core.viewport_packed());

        // The delta consumer is told it lost the damage, not handed silence.
        let delta = core.render_frame_delta(first.frame_version);
        assert!(delta.full_resync);
        assert_eq!(delta.resync_reason, FfiResyncReason::DamageOwnershipLost);
        hydrate(&mut cache, &delta);
        assert_eq!(cache, core.viewport_packed());

        // Same for the other two draining entry points.
        for drain in [0, 1] {
            let last = core.render_frame_delta(u64::MAX).frame_version;
            core.feed(b"\x1b[4;1Hmore".to_vec());
            if drain == 0 {
                core.take_damage();
            } else {
                core.snapshot();
            }
            let after = core.render_frame_delta(last);
            assert!(after.full_resync);
            assert_eq!(after.resync_reason, FfiResyncReason::DamageOwnershipLost);
        }

        // And the reverse direction: after a delta consumed the damage, a
        // full-frame caller still gets the complete, current viewport.
        core.feed(b"\x1b[5;1Hlate".to_vec());
        let _ = core.render_frame_delta(core.render_frame_delta(0).frame_version);
        assert_eq!(core.render_frame().packed_cells, core.viewport_packed());
    }

    #[test]
    fn test_render_frame_delta_payload_bytes_one_row_vs_full_100x50() {
        let core = TakoCore::new(100, 50);
        core.feed(b"warm up the grid".to_vec());

        let full = core.render_frame_delta(0);
        assert!(full.full_resync);
        let full_bytes = 100 * 50 * PACKED_CELL_SIZE;
        assert_eq!(full.packed_cells.len(), full_bytes); // 80_000
        assert_eq!(full.packed_cells.len(), core.viewport_packed().len());

        core.feed(b"\x1b[7;1Hjust this row".to_vec());
        let one_row = core.render_frame_delta(full.frame_version);
        assert!(!one_row.full_resync);
        assert_eq!(one_row.row_indices, vec![6]);
        let row_bytes = 100 * PACKED_CELL_SIZE;
        assert_eq!(one_row.packed_cells.len(), row_bytes); // 1_600
        assert_eq!(one_row.packed_cells.len() * 50, full.packed_cells.len());

        // The whole point: 2% of the bytes for the same on-screen result.
        assert_eq!(row_bytes, 1_600);
        assert_eq!(full_bytes, 80_000);
        let mut cache = full.packed_cells.clone();
        hydrate(&mut cache, &one_row);
        assert_eq!(cache, core.viewport_packed());
    }

    #[test]
    fn test_collapse_row_ranges_merges_runs_only() {
        assert_eq!(collapse_row_ranges(&[]), vec![]);
        assert_eq!(
            collapse_row_ranges(&[0, 1, 2, 7, 8, 11]),
            vec![
                FfiRowRange { start: 0, count: 3 },
                FfiRowRange { start: 7, count: 2 },
                FfiRowRange { start: 11, count: 1 },
            ]
        );
    }

    #[test]
    fn test_render_frame_delta_leaves_render_frame_behavior_intact() {
        let core = TakoCore::new(40, 10);
        core.feed(b"Hello, Tako FFI!\r\nLine 2".to_vec());

        let frame = core.render_frame();
        assert_eq!(frame.packed_cells.len(), 40 * 10 * PACKED_CELL_SIZE);
        assert!(frame.snapshot.damaged_rows.contains(&0));
        assert_eq!(frame.snapshot.cursor_row, 1);
        // Second render with no feed: damage gone, cells still complete.
        let again = core.render_frame();
        assert!(again.snapshot.damaged_rows.is_empty());
        assert_eq!(again.packed_cells, frame.packed_cells);
    }

    /// One packed row out of an overscan frame, by viewport index.
    fn packed_row(frame: &FfiRenderFrameOverscan, row: u32) -> &[u8] {
        let stride = frame.snapshot.cols as usize * PACKED_CELL_SIZE;
        let start = row as usize * stride;
        &frame.packed_cells[start..start + stride]
    }

    #[test]
    fn test_overscan_row_is_the_line_scrolling_down_would_reveal() {
        let core = TakoCore::new(20, 5);
        for i in 0..20 {
            core.feed(format!("L{i}\r\n").into_bytes());
        }
        core.scroll_viewport_up(3);

        let frame = core.render_frame_overscan(1);
        assert_eq!(frame.overscan_rows, 1);
        assert_eq!(
            frame.packed_cells.len(),
            (frame.snapshot.rows as usize + 1) * frame.snapshot.cols as usize * PACKED_CELL_SIZE,
            "the payload must carry the viewport plus the rows it claims"
        );
        let overscan = packed_row(&frame, frame.snapshot.rows).to_vec();

        // Scrolling one line down brings exactly one new row into view at the
        // bottom. That row is what the overscan strip had to be showing.
        core.scroll_viewport_down(1);
        let revealed = core.render_frame_overscan(0);
        let last_visible = packed_row(&revealed, revealed.snapshot.rows - 1);

        assert_eq!(
            overscan, last_visible,
            "the overscan row must be the next real line, not a repeat or a blank"
        );
    }

    #[test]
    fn test_at_the_tail_nothing_exists_below_the_viewport() {
        let core = TakoCore::new(20, 5);
        for i in 0..20 {
            core.feed(format!("L{i}\r\n").into_bytes());
        }
        // No scrollback offset: the last line is the bottom of the screen.
        let frame = core.render_frame_overscan(1);
        assert_eq!(frame.snapshot.viewport_offset, 0);

        let blank = TakoCore::new(20, 5).render_frame_overscan(0);
        assert_eq!(
            packed_row(&frame, frame.snapshot.rows),
            packed_row(&blank, 0),
            "below the live screen there is no line, so the strip must draw as blank"
        );
    }

    #[test]
    fn test_overscan_viewport_prefix_matches_render_frame_exactly() {
        let core = TakoCore::new(40, 8);
        core.feed(b"top\r\nmiddle\r\nbottom".to_vec());
        core.scroll_viewport_up(1);

        let plain = core.render_frame();
        let over = core.render_frame_overscan(1);

        let viewport_bytes = plain.packed_cells.len();
        assert_eq!(
            &over.packed_cells[..viewport_bytes],
            &plain.packed_cells[..],
            "a host ignoring the extra rows must see the frame it always saw"
        );
        assert_eq!(over.snapshot.rows, plain.snapshot.rows);
        assert_eq!(over.snapshot.cursor_row, plain.snapshot.cursor_row);
        assert_eq!(over.snapshot.viewport_offset, plain.snapshot.viewport_offset);
    }

    /// The overscan frame is the one a macOS surface presents whenever it is
    /// translating by a fraction of a row, so it has to answer the staleness
    /// question on the same terms as the plain frame. A host that had to ask
    /// the engine for its generation separately could not: `checkpoint_import`
    /// swaps the whole engine, and the two reads straddle it.
    #[test]
    fn test_overscan_frame_carries_the_same_epoch_as_the_plain_frame() {
        let core = TakoCore::new(20, 5);
        core.feed(b"before the import\r\n".to_vec());

        let before_plain = core.render_frame().epoch;
        let before_over = core.render_frame_overscan(1).epoch;
        assert_eq!(
            before_over, before_plain,
            "the overscan frame reported a different generation from the plain one"
        );

        let source = TakoCore::new(31, 7);
        source.feed(b"after the import\r\n".to_vec());
        let blob = source
            .checkpoint_export(0, 8 << 20)
            .expect("bounded export of a small terminal");
        core.checkpoint_import(blob).expect("honest checkpoint");

        let after_over = core.render_frame_overscan(1).epoch;
        assert_ne!(
            after_over, before_over,
            "an import replaced the engine without moving the overscan frame's epoch"
        );
        assert_eq!(
            after_over,
            core.render_frame().epoch,
            "the two frame calls disagree about which engine they came from"
        );
        assert_eq!(after_over, core.state_epoch());
    }

    #[test]
    fn test_overscan_request_is_clamped_not_honored_unbounded() {
        let core = TakoCore::new(10, 4);
        let frame = core.render_frame_overscan(9_000);
        assert_eq!(frame.overscan_rows, MAX_OVERSCAN_ROWS);
        assert_eq!(
            frame.packed_cells.len(),
            (4 + MAX_OVERSCAN_ROWS as usize) * 10 * PACKED_CELL_SIZE
        );
    }

    #[test]
    fn test_render_frame_payload_and_packed_size() {
        let core = TakoCore::new(80, 24);
        core.feed(b"Hello, Tako FFI!\r\nLine 2".to_vec());

        let frame = core.render_frame();

        // Metadata check
        assert_eq!(frame.snapshot.cols, 80);
        assert_eq!(frame.snapshot.rows, 24);
        assert_eq!(frame.snapshot.cursor_row, 1);
        assert_eq!(frame.snapshot.cursor_col, 6);
        assert!(frame.snapshot.cursor_visible);

        // Damaged rows check
        assert!(!frame.snapshot.damaged_rows.is_empty());

        // Packed cells exact size check: rows * cols * PACKED_CELL_SIZE
        let expected_packed_bytes = 80 * 24 * PACKED_CELL_SIZE;
        assert_eq!(frame.packed_cells.len(), expected_packed_bytes);

        // Verify snapshot() and viewport_packed() consistency
        let snap = core.snapshot();
        let packed = core.viewport_packed();
        assert_eq!(snap.cols, frame.snapshot.cols);
        assert_eq!(snap.rows, frame.snapshot.rows);
        assert_eq!(packed.len(), expected_packed_bytes);
    }

    #[test]
    fn test_render_frame_single_lock_tearing_prevention() {
        let core = TakoCore::new(40, 10);
        core.feed(b"Test lock consistency".to_vec());

        let frame = core.render_frame();
        assert_eq!(frame.snapshot.cols, 40);
        assert_eq!(frame.snapshot.rows, 10);
        assert_eq!(frame.packed_cells.len(), 40 * 10 * PACKED_CELL_SIZE);
    }

    #[test]
    fn test_feed_with_outcome_returns_output_and_events_once() {
        let core = TakoCore::new(40, 10);

        // Primary DA query (device reply) + BEL (host event) + text.
        let outcome = core.feed_with_outcome(b"hi\x07\x1b[c".to_vec());

        assert!(
            !outcome.output.is_empty(),
            "DA query should have queued a device reply"
        );
        assert_eq!(outcome.events, vec![FfiEvent::Bell]);

        // Drained by the feed itself: nothing is left for the legacy getters.
        assert!(core.take_output().is_empty());
        assert!(core.take_events().is_empty());
        // ... and a second feed_with_outcome doesn't re-report them either.
        let again = core.feed_with_outcome(Vec::new());
        assert!(again.output.is_empty());
        assert!(again.events.is_empty());
    }

    #[test]
    fn test_feed_with_outcome_has_damage_does_not_drain_rows() {
        let core = TakoCore::new(40, 10);

        let outcome = core.feed_with_outcome(b"first\r\nsecond".to_vec());
        assert!(outcome.has_damage);
        assert!(!outcome.synchronized_output_active);

        // Observing again still sees the same pending damage: nothing drained.
        let outcome2 = core.feed_with_outcome(Vec::new());
        assert!(outcome2.has_damage);

        // render_frame is the one consumer, and it still gets every row.
        let frame = core.render_frame();
        assert!(frame.snapshot.damaged_rows.contains(&0));
        assert!(frame.snapshot.damaged_rows.contains(&1));

        // Second render with no further feed: damage is gone.
        let frame2 = core.render_frame();
        assert!(frame2.snapshot.damaged_rows.is_empty());
        assert!(!core.feed_with_outcome(Vec::new()).has_damage);
    }

    #[test]
    fn test_feed_with_outcome_reports_post_feed_synchronized_output() {
        let core = TakoCore::new(40, 10);
        core.render_frame(); // clear initial damage

        // Open mode 2026: the frame is unfinished, so nothing is paintable yet.
        let opened = core.feed_with_outcome(b"\x1b[?2026hmid-frame".to_vec());
        assert!(opened.synchronized_output_active);
        assert!(
            !opened.has_damage,
            "mid Synchronized Output frame nothing may be painted"
        );
        assert!(core.render_frame().snapshot.damaged_rows.is_empty());

        // Close it: the whole bracket becomes visible at once.
        let closed = core.feed_with_outcome(b"\x1b[?2026l".to_vec());
        assert!(!closed.synchronized_output_active);
        assert!(closed.has_damage);
        assert!(!core.render_frame().snapshot.damaged_rows.is_empty());
    }

    #[test]
    fn test_takocore_modes_tracks_alternate_screen_and_alternate_scroll() {
        let core = TakoCore::new(80, 24);

        // Initial default: primary screen, alternate_scroll enabled (mode 1007 is ON by default)
        let m = core.modes();
        assert!(!m.alternate_screen);
        assert!(m.alternate_scroll);
        assert!(!core.snapshot().modes.alternate_screen);
        assert!(core.snapshot().modes.alternate_scroll);

        // Enter alternate screen via \e[?1049h
        core.feed(b"\x1b[?1049h".to_vec());
        let m = core.modes();
        assert!(m.alternate_screen);
        assert!(m.alternate_scroll);
        assert!(core.snapshot().modes.alternate_screen);

        // Disable DEC mode 1007 (alternate scroll) via \e[?1007l
        core.feed(b"\x1b[?1007l".to_vec());
        let m = core.modes();
        assert!(m.alternate_screen);
        assert!(!m.alternate_scroll);
        assert!(!core.snapshot().modes.alternate_scroll);

        // Leave alternate screen via \e[?1049l
        core.feed(b"\x1b[?1049l".to_vec());
        let m = core.modes();
        assert!(!m.alternate_screen);
        assert!(!m.alternate_scroll);

        // Soft reset restores mode 1007 default
        core.feed(b"\x1b[!p".to_vec());
        let m = core.modes();
        assert!(!m.alternate_screen);
        assert!(m.alternate_scroll);

        // Also works with modes 47 and 1047
        core.feed(b"\x1b[?47h".to_vec());
        assert!(core.modes().alternate_screen);
        core.feed(b"\x1b[?47l".to_vec());
        assert!(!core.modes().alternate_screen);

        core.feed(b"\x1b[?1047h".to_vec());
        assert!(core.modes().alternate_screen);
        core.feed(b"\x1b[?1047l".to_vec());
        assert!(!core.modes().alternate_screen);
    }

    // ------------------------------------------------------------------
    // The typed checkpoint surface Prod negotiates against.
    // ------------------------------------------------------------------

    #[test]
    fn checkpoint_version_negotiation_is_explicit() {
        let core = TakoCore::new(40, 10);
        assert_eq!(core.checkpoint_version(), 3);
        // v1 and v2 stay readable so a peer holding an older container is
        // not forced to discard it; v3 is what this build writes.
        assert!(core.checkpoint_supports(1));
        assert!(core.checkpoint_supports(2));
        assert!(core.checkpoint_supports(3));
        assert!(!core.checkpoint_supports(0));
        assert!(!core.checkpoint_supports(4));

        core.feed(b"negotiate".to_vec());
        let blob = core.checkpoint_export(0, 1 << 20).unwrap();

        // A newer container, correctly checksummed: a version failure, not
        // corruption. A bool could not tell the two apart.
        let mut newer = blob.clone();
        newer[4..8].copy_from_slice(&4u32.to_le_bytes());
        let crc = crate::terminal::checkpoint::crc32(&newer[20..]);
        newer[16..20].copy_from_slice(&crc.to_le_bytes());

        let dest = TakoCore::new(20, 6);
        assert_eq!(
            dest.checkpoint_import(newer.clone()),
            Err(TakoCheckpointError::UnsupportedVersion { version: 4 })
        );
        assert_eq!(
            dest.checkpoint_inspect(newer),
            Err(TakoCheckpointError::UnsupportedVersion { version: 4 })
        );

        let mut corrupt = blob.clone();
        let last = corrupt.len() - 1;
        corrupt[last] ^= 0xFF;
        assert!(matches!(
            dest.checkpoint_import(corrupt),
            Err(TakoCheckpointError::Corrupt { .. })
        ));

        let info = dest.checkpoint_inspect(blob.clone()).unwrap();
        assert_eq!((info.version, info.cols, info.rows), (3, 40, 10));
        assert_eq!(info.payload_len as usize, blob.len() - 20);
        assert_eq!(dest.checkpoint_import(blob), Ok(()));
    }

    #[test]
    fn checkpoint_export_refuses_at_the_caller_supplied_cap() {
        let core = TakoCore::new(40, 10);
        core.feed(b"bounded".to_vec());
        let full = core.checkpoint_export(0, u64::MAX).unwrap();

        match core.checkpoint_export(0, 32) {
            Err(TakoCheckpointError::TooLarge { size, limit }) => {
                assert_eq!(limit, 32);
                assert!(size > 32);
            }
            other => panic!("expected TooLarge, got {other:?}"),
        }
        // Refusing changed nothing.
        assert_eq!(core.checkpoint_export(0, u64::MAX).unwrap(), full);
        // 0 is "no caller limit", not a limit of zero: it yields the same
        // checkpoint the library ceiling does, not an error.
        assert_eq!(core.checkpoint_export(0, 0).unwrap(), full);
        // A cap of exactly the blob's size is enough, one byte less is not:
        // the cap covers the container header, so the caller's transport bound
        // is the whole blob.
        assert_eq!(
            core.checkpoint_export(0, full.len() as u64).unwrap().len(),
            full.len()
        );
        match core.checkpoint_export(0, full.len() as u64 - 1) {
            Err(TakoCheckpointError::TooLarge { size, limit }) => {
                assert_eq!(size, full.len() as u64);
                assert_eq!(limit, full.len() as u64 - 1);
            }
            other => panic!("expected TooLarge one byte under the blob, got {other:?}"),
        }
        assert_eq!(
            core.checkpoint_import(Vec::new()),
            Err(TakoCheckpointError::NullArgument)
        );
    }

    #[test]
    fn checkpoint_import_is_fail_intact_and_publishes_an_epoch() {
        let dest = TakoCore::new(60, 20);
        dest.feed(b"DESTINATION\r\nsecond".to_vec());
        let before = dest.checkpoint_export(0, u64::MAX).unwrap();
        let epoch_before = dest.state_epoch();

        for blob in [Vec::new(), vec![1, 2, 3], before[..8].to_vec()] {
            assert!(dest.checkpoint_import(blob).is_err());
            assert_eq!(
                dest.checkpoint_export(0, u64::MAX).unwrap(),
                before,
                "a rejected import leaves the destination byte-identical"
            );
            assert_eq!(dest.state_epoch(), epoch_before, "and does not move the epoch");
        }

        let source = TakoCore::new(30, 8);
        source.feed(b"SOURCE".to_vec());
        let good = source.checkpoint_export(0, u64::MAX).unwrap();
        dest.checkpoint_import(good.clone()).unwrap();
        assert!(dest.state_epoch() > epoch_before, "a swap publishes a new epoch");
        assert_eq!(dest.checkpoint_export(0, u64::MAX).unwrap(), good);
        assert_eq!(dest.cols(), 30);
        assert_eq!(dest.rows(), 8);
    }

    #[test]
    fn feed_outcomes_and_frames_carry_the_epoch_they_were_taken_under() {
        let core = TakoCore::new(40, 10);
        let first = core.feed_with_outcome(b"before".to_vec());
        assert_eq!(first.epoch, core.state_epoch());
        assert_eq!(core.render_frame().epoch, first.epoch);

        let source = TakoCore::new(40, 10);
        source.feed(b"after".to_vec());
        core.checkpoint_import(source.checkpoint_export(0, u64::MAX).unwrap())
            .unwrap();

        // The outcome captured before the swap is now stale, and says so.
        assert_ne!(first.epoch, core.state_epoch());
        let second = core.feed_with_outcome(b"!".to_vec());
        assert_eq!(second.epoch, core.state_epoch());
        assert_eq!(core.render_frame().epoch, second.epoch);

        // `reset` replaces the engine too, so it moves the epoch as well.
        let epoch = core.state_epoch();
        core.reset();
        assert_ne!(core.state_epoch(), epoch);
    }
}
