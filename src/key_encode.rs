bitflags::bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub struct Mods: u8 {
        const SHIFT = 1;
        const ALT = 2;
        const CTRL = 4;
        const SUPER = 8;
        /// Lock-key state, not a bindable modifier. Kitty reports it
        /// separately in the CSI u modifier field and, unlike shift, it does
        /// not by itself flip a key's reported alternate codepoint.
        const CAPS_LOCK = 16;
        const NUM_LOCK = 32;
    }
}

impl Mods {
    /// The bindable modifiers only -- drops the lock keys. Upstream's
    /// `Mods.binding()`: used to decide whether a key is "held with no
    /// modifier" for the purposes of legacy passthrough/disambiguation,
    /// where caps lock or num lock alone must not count as a modifier.
    fn binding(self) -> Mods {
        self & (Mods::SHIFT | Mods::ALT | Mods::CTRL | Mods::SUPER)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Key {
    Enter, Tab, Backspace, Escape, Space,
    Up, Down, Right, Left, Home, End, PageUp, PageDown, Insert, Delete,
    F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12,
    KeypadEnter, KeypadPlus, KeypadMinus, KeypadMultiply, KeypadDivide,
    Keypad0, Keypad1, Keypad2, Keypad3, Keypad4, Keypad5, Keypad6, Keypad7, Keypad8, Keypad9,
    /// The modifier keys as events in their own right, only ever reported
    /// under the Kitty protocol's `report_all` flag (upstream's
    /// `shift_left`/`shift_right`/etc; there is no `super_left`/`super_right`
    /// in upstream's Kitty key table, so none exists here either).
    ShiftLeft, ShiftRight, ControlLeft, ControlRight, AltLeft, AltRight, MetaLeft, MetaRight,
    /// Text with no key behind it -- e.g. IME-composed text delivered
    /// without an originating physical key.
    Unidentified,
    Char(char),
}

/// Whether the macOS "option" key is treated as Alt for text-suppression
/// purposes (Kitty's `report_associated`) and legacy alt-prefixing, or as a
/// dead-key modifier that still produces composed text. See upstream's
/// `macos-option-as-alt` config.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum OptionAsAlt {
    #[default]
    False,
    True,
    Left,
    Right,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyEvent {
    pub key: Key,
    pub mods: Mods,
    pub repeat: bool,
    pub press: bool,
    /// The character the key produces with no modifiers applied.
    ///
    /// The Kitty keyboard protocol identifies a key by its *base* codepoint
    /// and reports shift separately, so `shift+a` is `CSI 97;2u` and never
    /// `CSI 65;2u` -- a receiver that gets the shifted codepoint has no way
    /// to tell which physical key was pressed and drops it. Legacy encoding
    /// still uses the shifted character, which is the text the key produced.
    pub unshifted: Option<char>,
    /// Which key this physically is, as the ASCII it would type on a US
    /// layout.
    ///
    /// On a Cyrillic layout the `c` key types U+0441 and its unshifted
    /// codepoint is U+0441 too, so neither says that this is the `c` key --
    /// and every terminal still sends 0x03 for it. Upstream calls this the
    /// logical key.
    pub physical: Option<char>,
    /// The text this event actually committed -- upstream's `event.utf8`.
    /// Multi-codepoint for an IME/dead-key commit (e.g. `"abcd"`). `None`
    /// falls back to `key`'s own character for `Key::Char`, matching a host
    /// that never populates this separately from the key.
    pub text: Option<String>,
    /// True while a dead-key/IME composition is in progress and this event
    /// has not committed text yet. Upstream's `event.composing`.
    pub composing: bool,
}

impl KeyEvent {
    pub fn new(key: Key) -> Self {
        Self {
            key,
            mods: Mods::empty(),
            repeat: false,
            press: true,
            unshifted: None,
            physical: None,
            text: None,
            composing: false,
        }
    }

    /// Upstream's `event.utf8`: the committed text for this event, falling
    /// back to `Key::Char`'s own character when the host didn't report text
    /// separately.
    fn utf8(&self) -> Option<std::borrow::Cow<'_, str>> {
        if let Some(text) = &self.text {
            return Some(std::borrow::Cow::Borrowed(text.as_str()));
        }
        match self.key {
            Key::Char(c) => {
                let mut buf = [0u8; 4];
                Some(std::borrow::Cow::Owned(c.encode_utf8(&mut buf).to_string()))
            }
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct EncodeConfig {
    pub cursor_key_app_mode: bool,   // DECCKM
    pub keypad_app_mode: bool,       // DECKPAM
    pub kitty_flags: u8,             // Kitty keyboard progressive-enhancement bits
    pub alt_esc_prefix: bool,        // Alt sends ESC prefix (macOS option-as-meta)
    pub macos_option_as_alt: OptionAsAlt,
    /// DEC Backarrow Key Mode. Off (the default): backspace sends 0x7F, and
    /// ctrl+backspace sends 0x08. On: swapped.
    pub backarrow_key_mode: bool,
    /// xterm's "modifyOtherKeys" state 2: ctrl/alt/shift combinations on a
    /// character key that would otherwise lose their modifiers (or collide
    /// with another sequence) go out as `CSI 27;mods;codepoint~` instead.
    pub modify_other_keys_state_2: bool,
    /// DEC mode 1035. When true (the common modern default), a numpad
    /// digit's own DEC keypad-application-mode encoding is never used --
    /// numlock's real state decides digit-vs-SS3 instead, which upstream
    /// models as the apprt simply not requesting application mode for that
    /// key. We have no separate numpad-vs-top-row signal, so this flag is
    /// the only thing that can suppress it here.
    pub ignore_keypad_with_numlock: bool,
}

fn is_control(cp: u32) -> bool {
    cp < 0x20 || cp == 0x7F
}

/// True for a string that is exactly one control character -- upstream's
/// `isControlUtf8`, used to tell a real dead-key/IME text commit (which
/// wins over a key's default bytes) from a host echoing a bare control
/// byte back as "text" (which should not).
fn is_control_utf8(s: &str) -> bool {
    let mut chars = s.chars();
    matches!((chars.next(), chars.next()), (Some(c), None) if is_control(c as u32))
}

/// The legacy terminal interrupt byte is retained only for a literal Ctrl+C
/// key press. This compatibility exception lets hosts with a visible Ctrl+C
/// key cancel an interactive prompt after it enables Kitty disambiguation,
/// while applications that request report-all still receive CSI-u.
fn is_pure_ctrl_c_press(event: &KeyEvent) -> bool {
    event.press
        && event.mods.binding() == Mods::CTRL
        && (matches!(event.key, Key::Char('c') | Key::Char('C'))
            || matches!(event.unshifted, Some('c') | Some('C'))
            || matches!(event.physical, Some('c') | Some('C')))
}

pub fn encode(event: KeyEvent, config: EncodeConfig) -> Vec<u8> {
    if config.kitty_flags != 0 {
        return encode_kitty(event, config);
    }
    encode_legacy(event, config)
}

/// A key's entry in the Kitty keyboard protocol's key table: its assigned
/// code, the CSI final byte to use, and whether it is a bare modifier key
/// (only ever reported under `report_all`).
///
/// Ported from upstream's `kitty` (`raw_entries`), which is
/// itself ported from Foot's `kitty-keymap.h`. Only the entries our `Key`
/// enum can produce are included.
struct KittyEntry {
    code: u32,
    final_byte: u8,
    modifier: bool,
}

fn kitty_entry(key: Key) -> Option<KittyEntry> {
    let (code, final_byte, modifier) = match key {
        Key::Escape => (27, b'u', false),
        Key::Enter => (13, b'u', false),
        Key::Tab => (9, b'u', false),
        Key::Backspace => (127, b'u', false),
        Key::Insert => (2, b'~', false),
        Key::Delete => (3, b'~', false),
        Key::Left => (1, b'D', false),
        Key::Right => (1, b'C', false),
        Key::Up => (1, b'A', false),
        Key::Down => (1, b'B', false),
        Key::PageUp => (5, b'~', false),
        Key::PageDown => (6, b'~', false),
        Key::Home => (1, b'H', false),
        Key::End => (1, b'F', false),
        Key::F1 => (1, b'P', false),
        Key::F2 => (1, b'Q', false),
        // F3 is the one named function key that does not get an SS3 letter
        // -- upstream's table gives it code 13 with the tilde form instead.
        Key::F3 => (13, b'~', false),
        Key::F4 => (1, b'S', false),
        Key::F5 => (15, b'~', false),
        Key::F6 => (17, b'~', false),
        Key::F7 => (18, b'~', false),
        Key::F8 => (19, b'~', false),
        Key::F9 => (20, b'~', false),
        Key::F10 => (21, b'~', false),
        Key::F11 => (23, b'~', false),
        Key::F12 => (24, b'~', false),
        Key::Keypad0 => (57399, b'u', false),
        Key::Keypad1 => (57400, b'u', false),
        Key::Keypad2 => (57401, b'u', false),
        Key::Keypad3 => (57402, b'u', false),
        Key::Keypad4 => (57403, b'u', false),
        Key::Keypad5 => (57404, b'u', false),
        Key::Keypad6 => (57405, b'u', false),
        Key::Keypad7 => (57406, b'u', false),
        Key::Keypad8 => (57407, b'u', false),
        Key::Keypad9 => (57408, b'u', false),
        Key::KeypadDivide => (57410, b'u', false),
        Key::KeypadMultiply => (57411, b'u', false),
        Key::KeypadMinus => (57412, b'u', false),
        Key::KeypadPlus => (57413, b'u', false),
        Key::KeypadEnter => (57414, b'u', false),
        Key::ShiftLeft => (57441, b'u', true),
        Key::ShiftRight => (57447, b'u', true),
        Key::ControlLeft => (57442, b'u', true),
        Key::ControlRight => (57448, b'u', true),
        Key::MetaLeft => (57444, b'u', true),
        Key::MetaRight => (57450, b'u', true),
        Key::AltLeft => (57443, b'u', true),
        Key::AltRight => (57449, b'u', true),
        Key::Space | Key::Char(_) | Key::Unidentified => return None,
    };
    Some(KittyEntry { code, final_byte, modifier })
}

/// The layout-independent codepoint a key represents -- upstream's
/// `Key.codepoint()`, used as the "base layout key" alternate. Only
/// `Key::Char` carries one; every named key in `kitty_entry`'s table already
/// has a fixed protocol code and never reports a base-layout alternate.
fn key_base_codepoint(key: Key) -> Option<u32> {
    match key {
        Key::Char(c) => Some(c as u32),
        _ => None,
    }
}

/// The shifted form of an ASCII symbol/digit on a US QWERTY layout --
/// there's no general rule for these the way there is for letters. Unicode
/// case-folding covers letters, including non-Latin scripts.
fn us_shifted(c: char) -> char {
    match c {
        '`' => '~', '1' => '!', '2' => '@', '3' => '#', '4' => '$', '5' => '%',
        '6' => '^', '7' => '&', '8' => '*', '9' => '(', '0' => ')', '-' => '_',
        '=' => '+', '[' => '{', ']' => '}', '\\' => '|', ';' => ':', '\'' => '"',
        ',' => '<', '.' => '>', '/' => '?',
        _ => c.to_uppercase().next().unwrap_or(c),
    }
}

/// Perform Kitty keyboard protocol encoding of the key event.
///
/// Ported from upstream's `kitty()`. Structure
/// mirrors upstream closely: find the key's table entry (or fall back to its
/// unshifted codepoint), handle dead-key/composing/plain-text preprocessing,
/// then build and encode the CSI u sequence.
fn encode_kitty(event: KeyEvent, config: EncodeConfig) -> Vec<u8> {
    let report_events = (config.kitty_flags & 2) != 0;
    let report_alternates = (config.kitty_flags & 4) != 0;
    let report_all = (config.kitty_flags & 8) != 0;
    let report_associated = (config.kitty_flags & 16) != 0;

    // We only process "press" events unless report_events is active. Enter,
    // backspace and tab additionally never report release events unless
    // report_all is set too, so a program relying on a single release does
    // not spuriously see one for these.
    if !event.press && !event.repeat {
        if !report_events {
            return Vec::new();
        }
        if !report_all && matches!(event.key, Key::Enter | Key::Backspace | Key::Tab) {
            return Vec::new();
        }
    }

    let binding_mods = event.mods.binding();
    let utf8 = event.utf8();

    // Find this key's entry, falling back to its unshifted codepoint when
    // it isn't a functional/predefined key (e.g. a plain letter).
    let entry = kitty_entry(event.key).or_else(|| {
        event.unshifted.map(|u| KittyEntry {
            code: u as u32,
            final_byte: b'u',
            modifier: false,
        })
    });

    // When composing, only plain modifier-key events are sent.
    if event.composing {
        match &entry {
            Some(e) if e.modifier => {}
            _ => return Vec::new(),
        }
    } else {
        // IME confirmation still sends an enter/backspace key, so if we have
        // committed text we send it directly rather than the key's normal
        // sequence -- unless the text is itself a single control character,
        // which means this isn't actually dead-key text.
        if let Some(text) = &utf8
            && !text.is_empty() && !is_control_utf8(text) {
                match event.key {
                    Key::Backspace => return Vec::new(),
                    Key::Enter => return text.as_bytes().to_vec(),
                    _ => {}
                }
            }

        if !report_all {
            // Enter, Tab and Backspace still generate their legacy bytes so
            // a user can type `reset` after a program that set this mode
            // crashes without clearing it.
            if binding_mods.is_empty() {
                match event.key {
                    Key::Enter => return b"\r".to_vec(),
                    Key::Tab => return b"\t".to_vec(),
                    Key::Backspace => return b"\x7f".to_vec(),
                    _ => {}
                }
            }

            // Ctrl+C remains ETX when an application has not explicitly
            // requested every key as CSI-u. This narrowly preserves terminal
            // interrupt/cancel for a visible mobile Ctrl+C key in an
            // alternate-screen prompt; shifted and modified variants, event
            // releases, and every non-C control key retain normal Kitty
            // encoding.
            if is_pure_ctrl_c_press(&event) {
                return vec![0x03];
            }

            // Plain text goes straight to the terminal rather than through
            // a CSI sequence -- and unlike the enter/tab/backspace shortcut
            // above, shift alone does not block this, UNLESS the app asked
            // for report_alternates: an app that wants base-vs-shifted
            // separation needs the CSI form to get it, but one that
            // doesn't just wants the text. Without this exception, a
            // protocol-aware shell (fish, by default) that gets `CSI
            // 97;2u` for shift+a has no way to recover the text and drops
            // the event -- shift used to type nothing at all because of
            // this distinction being missed.
            let text_binding_mods = if report_alternates {
                binding_mods
            } else {
                binding_mods - Mods::SHIFT
            };
            if let Some(text) = &utf8
                && text_binding_mods.is_empty()
                    && event.press
                    && !text.is_empty()
                    && !text.chars().any(|c| is_control(c as u32))
                {
                    return text.as_bytes().to_vec();
                }
        }
    }

    let Some(entry) = entry else {
        // No table entry and no unshifted codepoint: this is pure composed
        // text with no key behind it (e.g. IME), so send it as-is.
        return match &utf8 {
            Some(text) if !text.is_empty() => text.as_bytes().to_vec(),
            _ => Vec::new(),
        };
    };

    // A bare modifier key only gets a sequence under report_all.
    if entry.modifier && !report_all {
        return Vec::new();
    }

    let mut kitty_mods = 0u32;
    if event.mods.contains(Mods::SHIFT) {
        kitty_mods |= 1;
    }
    if event.mods.contains(Mods::ALT) {
        kitty_mods |= 2;
    }
    if event.mods.contains(Mods::CTRL) {
        kitty_mods |= 4;
    }
    if event.mods.contains(Mods::SUPER) {
        kitty_mods |= 8;
    }
    if event.mods.contains(Mods::CAPS_LOCK) {
        kitty_mods |= 64;
    }
    if event.mods.contains(Mods::NUM_LOCK) {
        kitty_mods |= 128;
    }
    let mods_int = kitty_mods + 1;

    // Kitty omits the ":1" for a plain press (event_val 0 and 1 behave
    // identically below); only repeat/release change the encoding.
    let event_val: u8 = if report_events {
        if !event.press {
            3
        } else if event.repeat {
            2
        } else {
            1
        }
    } else {
        0
    };

    // What this exact keypress produced as text: the host's own text when
    // it gave us one, else derived from `unshifted` -- shifted/uppercased
    // when shift OR caps lock is held (either one makes a real layout
    // produce the shifted form), otherwise the layout's plain output.
    // Upstream always has this from a real multi-codepoint `event.utf8`
    // string; single-codepoint derivation covers every test and every real
    // key event, which never carries more than one committed codepoint
    // outside of dead-key/IME commits (handled separately, above).
    let produced = event.text.clone().or_else(|| {
        event.unshifted.map(|u| {
            if event.mods.contains(Mods::SHIFT) || event.mods.contains(Mods::CAPS_LOCK) {
                us_shifted(u).to_string()
            } else {
                u.to_string()
            }
        })
    });
    let cp1 = produced.as_ref().and_then(|s| s.chars().next()).map(|c| c as u32);

    let mut alternates: [Option<u32>; 2] = [None, None];
    if report_alternates && !is_control(entry.code) {
        if let Some(cp1) = cp1 {
            // Only real shift, not caps lock, reports a shifted alternate --
            // upstream gates this on `seq.mods.shift` specifically.
            if cp1 != entry.code && event.mods.contains(Mods::SHIFT) {
                alternates[0] = Some(cp1);
            }
            if let Some(base) = key_base_codepoint(event.key)
                && base != entry.code && cp1 != base {
                    alternates[1] = Some(base);
                }
        } else if let Some(base) = key_base_codepoint(event.key)
            && base != entry.code {
                alternates[1] = Some(base);
            }
    }

    let mut text: Option<String> = None;
    if report_associated && event_val != 3 {
        let alt_prevents_text = match config.macos_option_as_alt {
            OptionAsAlt::Left | OptionAsAlt::Right => event.mods.contains(Mods::ALT), // sides not tracked
            OptionAsAlt::True => true,
            OptionAsAlt::False => false,
        };
        let prevents_text = (event.mods.contains(Mods::ALT) && alt_prevents_text)
            || event.mods.contains(Mods::CTRL)
            || event.mods.contains(Mods::SUPER);
        if !prevents_text {
            text = produced;
        }
    }

    kitty_sequence_encode(entry.code, entry.final_byte, mods_int, event_val, alternates, text.as_deref())
}

/// The Kitty CSI u/CSI-special sequence formatter in isolation, ported from
/// upstream's `KittySequence.encode`. `pub`
/// because upstream's own `KittySequence: ...` tests exercise this directly
/// rather than through the full `kitty()` pipeline -- see
/// `tests/parity_key_kitty.rs`.
///
/// `mods_int` is upstream's `KittyMods.seqInt()` (the "1 + bitmask" value,
/// never 0); `event_val` is 0 for no event reported, 1 for press, 2 for
/// repeat, 3 for release -- 0 and 1 behave identically, matching upstream's
/// `Event.none`/`Event.press`.
pub fn kitty_sequence_encode(
    key: u32,
    final_byte: u8,
    mods_int: u32,
    event_val: u8,
    alternates: [Option<u32>; 2],
    text: Option<&str>,
) -> Vec<u8> {
    if final_byte == b'u' || final_byte == b'~' {
        kitty_encode_full(key, final_byte, mods_int, event_val, alternates, text)
    } else {
        kitty_encode_special(final_byte, mods_int, event_val)
    }
}

fn kitty_encode_full(
    key: u32,
    final_byte: u8,
    mods_int: u32,
    event_val: u8,
    alternates: [Option<u32>; 2],
    text: Option<&str>,
) -> Vec<u8> {
    let mut out = format!("\x1b[{key}");
    if let Some(shifted) = alternates[0] {
        out.push_str(&format!(":{shifted}"));
    }
    if let Some(base) = alternates[1] {
        if alternates[0].is_none() {
            out.push_str(&format!("::{base}"));
        } else {
            out.push_str(&format!(":{base}"));
        }
    }

    let mut emit_prior = false;
    if event_val > 1 {
        out.push_str(&format!(";{mods_int}:{event_val}"));
        emit_prior = true;
    } else if mods_int > 1 {
        out.push_str(&format!(";{mods_int}"));
        emit_prior = true;
    }

    if let Some(text) = text {
        let mut count = 0;
        for cp in text.chars() {
            if is_control(cp as u32) {
                continue;
            }
            if count == 0 {
                if !emit_prior {
                    out.push(';');
                }
                out.push(';');
            } else {
                out.push(':');
            }
            out.push_str(&(cp as u32).to_string());
            count += 1;
        }
    }

    out.push(final_byte as char);
    out.into_bytes()
}

fn kitty_encode_special(final_byte: u8, mods_int: u32, event_val: u8) -> Vec<u8> {
    if event_val > 1 {
        return format!("\x1b[1;{mods_int}:{event_val}{}", final_byte as char).into_bytes();
    }
    if mods_int > 1 {
        return format!("\x1b[1;{mods_int}{}", final_byte as char).into_bytes();
    }
    format!("\x1b[{}", final_byte as char).into_bytes()
}

fn encode_legacy(event: KeyEvent, config: EncodeConfig) -> Vec<u8> {
    let kitty_active = false;
    let report_events = false;

    if !event.press && !report_events {
        return Vec::new();
    }

    let m = 1 + event.mods.binding().bits();

    let mod_str = if m != 1 { Some(format!("{m}")) } else { None };

    let disambiguate = false;

    match event.key {
        Key::Up => encode_arrow('A', config, mod_str),
        Key::Down => encode_arrow('B', config, mod_str),
        Key::Right => encode_arrow('C', config, mod_str),
        Key::Left => encode_arrow('D', config, mod_str),
        Key::Home => encode_arrow('H', config, mod_str),
        Key::End => encode_arrow('F', config, mod_str),

        Key::Insert => encode_tilde(2, mod_str),
        Key::Delete => encode_tilde(3, mod_str),
        Key::PageUp => encode_tilde(5, mod_str),
        Key::PageDown => encode_tilde(6, mod_str),

        Key::F1 => encode_f1_f4('P', mod_str),
        Key::F2 => encode_f1_f4('Q', mod_str),
        // F3 is the one named function key with no SS3 letter of its own --
        // it shares the tilde form and code 13 with Enter (see
        // `kitty_entry`'s table, which upstream's legacy table agrees with).
        Key::F3 => encode_tilde(13, mod_str),
        Key::F4 => encode_f1_f4('S', mod_str),

        Key::F5 => encode_tilde(15, mod_str),
        Key::F6 => encode_tilde(17, mod_str),
        Key::F7 => encode_tilde(18, mod_str),
        Key::F8 => encode_tilde(19, mod_str),
        Key::F9 => encode_tilde(20, mod_str),
        Key::F10 => encode_tilde(21, mod_str),
        Key::F11 => encode_tilde(23, mod_str),
        Key::F12 => encode_tilde(24, mod_str),

        Key::KeypadEnter => {
            if config.keypad_app_mode {
                b"\x1bOM".to_vec()
            } else {
                encode_ambiguous(13, b"\r", event, config, disambiguate, mod_str, false)
            }
        }
        Key::KeypadPlus => {
            if config.keypad_app_mode {
                b"\x1bOk".to_vec()
            } else {
                encode_ambiguous('+' as u32, b"+", event, config, disambiguate, mod_str, true)
            }
        }
        Key::KeypadMinus => {
            if config.keypad_app_mode {
                b"\x1bOm".to_vec()
            } else {
                encode_ambiguous('-' as u32, b"-", event, config, disambiguate, mod_str, true)
            }
        }
        Key::KeypadMultiply => {
            if config.keypad_app_mode {
                b"\x1bOj".to_vec()
            } else {
                encode_ambiguous('*' as u32, b"*", event, config, disambiguate, mod_str, true)
            }
        }
        Key::KeypadDivide => {
            if config.keypad_app_mode {
                b"\x1bOo".to_vec()
            } else {
                encode_ambiguous('/' as u32, b"/", event, config, disambiguate, mod_str, true)
            }
        }

        Key::Enter => {
            // An IME confirmation still sends an Enter key, so committed
            // dead-key text (not itself a single control character) wins
            // over Enter's own bytes -- upstream's comment: escape/enter/
            // backspace all have a specific meaning mid-composition, so we
            // must not send their PC-style sequence over real commit text.
            if let Some(text) = &event.text
                && !text.is_empty() && !is_control_utf8(text) {
                    return text.as_bytes().to_vec();
                }
            encode_ambiguous(13, b"\r", event, config, disambiguate, mod_str, false)
        }
        Key::Tab => {
            if !kitty_active && event.mods.contains(Mods::SHIFT) {
                let mut bytes = b"\x1b[Z".to_vec();
                if event.mods.contains(Mods::ALT) && config.alt_esc_prefix {
                    bytes.insert(0, 0x1b);
                }
                bytes
            } else {
                encode_ambiguous(9, b"\t", event, config, disambiguate, mod_str, false)
            }
        }
        Key::Backspace => {
            // Backspace's dead-key text commit encodes nothing: the IME
            // already modified the preedit buffer, so there is nothing
            // left to send (upstream: "backspace encodes nothing because
            // we modified IME").
            if let Some(text) = &event.text
                && !text.is_empty() && !is_control_utf8(text) {
                    return Vec::new();
                }
            // DEC Backarrow Key Mode (DECBKM): off sends 0x7F and ctrl+
            // backspace sends 0x08; on swaps them.
            let ctrl = !kitty_active && event.mods.contains(Mods::CTRL);
            let default_bytes: &[u8] = match (config.backarrow_key_mode, ctrl) {
                (false, false) => b"\x7f",
                (false, true) => b"\x08",
                (true, false) => b"\x08",
                (true, true) => b"\x7f",
            };
            encode_ambiguous(127, default_bytes, event, config, disambiguate, mod_str, false)
        }
        Key::Escape => {
            // Same dead-key-text priority as Enter: e.g. on Japanese input,
            // escape clears (rather than commits) the composition, so a
            // real text commit still wins over escape's own byte.
            if let Some(text) = &event.text
                && !text.is_empty() && !is_control_utf8(text) {
                    return text.as_bytes().to_vec();
                }
            encode_ambiguous(27, b"\x1b", event, config, disambiguate, mod_str, false)
        }
        Key::Space => {
            let default_bytes = if !kitty_active && event.mods.contains(Mods::CTRL) {
                b"\x00".as_slice()
            } else {
                b" ".as_slice()
            };
            encode_ambiguous(32, default_bytes, event, config, disambiguate, mod_str, true)
        }

        Key::Char(c) => {
            // Keypad application mode (DECKPAM) applies to the digit keys
            // too, not just the named keypad symbols -- upstream's
            // function-key table covers numpad_0..9 the same way it covers
            // numpad_enter etc. We have no separate "this came from the
            // numpad, not the top row" signal, so this applies to any
            // digit character key; `ignore_keypad_with_numlock` (DEC mode
            // 1035) is how a host suppresses it.
            if config.keypad_app_mode
                && !config.ignore_keypad_with_numlock
                && c.is_ascii_digit()
            {
                let letter = (b'p' + c as u8 - b'0') as char;
                return format!("\x1bO{letter}").into_bytes();
            }

            // The key number identifies the key, not the character it made:
            // the physical key first, then its unmodified form, then the
            // character itself. On a Cyrillic layout only the first of those
            // says this is the `c` key, which is what lets `ctrl+c` work
            // there under the Kitty protocol as well as without it.
            let codepoint = event
                .physical
                .filter(char::is_ascii)
                .or(event.unshifted)
                .unwrap_or(c) as u32;

            if !kitty_active && event.mods.contains(Mods::CTRL) {
                let mut text_buf = [0u8; 4];
                let text = c.encode_utf8(&mut text_buf);
                if let Some(byte) = ctrl_seq(text, event.unshifted, event.physical, event.mods) {
                    let raw_bytes = [byte];
                    return encode_ambiguous(
                        codepoint, &raw_bytes, event, config, disambiguate, mod_str, true,
                    );
                }
            }

            // xterm's modifyOtherKeys state 2: ctrl/alt/shift combinations
            // that would otherwise lose their modifiers -- or collide with
            // another sequence -- go out as `CSI 27;mods;codepoint~`
            // instead. Checked after ctrlSeq (which gets first refusal) but
            // regardless of whether ctrl is held at all, since it also
            // covers plain alt+key.
            if config.modify_other_keys_state_2
                && let Some(out) = modify_other_keys(c, event.mods, config.macos_option_as_alt) {
                    return out;
                }

            // The fixterms CSI u fallback: ctrl+letters that deliberately
            // have no C0 byte (i, m, [ -- see `ctrl_seq`'s doc comment) and
            // ctrl+shift+letter, which must stay distinguishable from
            // plain ctrl+letter.
            if !kitty_active && event.mods.contains(Mods::CTRL) {
                return fixterms_csi_u(c, event.unshifted, event.mods);
            }

            // On macOS, super+key never encodes text -- native apps and
            // other terminals (Terminal.app, iTerm2) agree on this. Linux
            // continues to encode text since that's typical there, but
            // this crate has only ever targeted macOS/iOS hosts.
            if event.mods.contains(Mods::SUPER) {
                return Vec::new();
            }

            let raw_bytes = match &event.text {
                Some(text) if !text.is_empty() => text.as_bytes().to_vec(),
                _ => {
                    let mut buf = [0u8; 4];
                    c.encode_utf8(&mut buf).as_bytes().to_vec()
                }
            };
            encode_ambiguous(codepoint, &raw_bytes, event, config, disambiguate, mod_str, true)
        }

        // Numpad digits, the standalone modifier-key events and text with
        // no key behind it only ever exist under the Kitty protocol (see
        // `encode_kitty`'s entry table); legacy mode has no representation
        // for them.
        Key::Keypad0 | Key::Keypad1 | Key::Keypad2 | Key::Keypad3 | Key::Keypad4
        | Key::Keypad5 | Key::Keypad6 | Key::Keypad7 | Key::Keypad8 | Key::Keypad9
        | Key::ShiftLeft | Key::ShiftRight | Key::ControlLeft | Key::ControlRight
        | Key::AltLeft | Key::AltRight | Key::MetaLeft | Key::MetaRight
        | Key::Unidentified => Vec::new(),
    }
}

/// The C0 byte a key produces with control held, or `None` when it produces
/// none and the caller should fall through to CSI u.
///
/// Ported from upstream's `ctrlSeq`. Two parts of
/// it are not obvious and both matter:
///
/// The typed character is not always the one to map. On a Cyrillic layout the
/// `c` key types U+0441, and every terminal still sends 0x03 for it -- so
/// when the text is not a single byte, the key's *unshifted* codepoint is
/// used instead. That only holds when control is the only modifier, because
/// with shift there is no way to know what the layout would have produced.
///
/// `ctrl+shift+m` deliberately does not produce 0x0D. Leaving shift set makes
/// the final check fail, and the caller encodes CSI u instead, which is what
/// lets a program tell `ctrl+m` from `ctrl+shift+m`. Upstream notes this
/// diverges from fixterms and matches Kitty.
///
/// `pub` because upstream's own `ctrlseq: ...` tests exercise this function
/// in isolation (checking only whether it recognizes a combination, not
/// what the full `encode()` pipeline eventually does with a `None`) -- see
/// `tests/parity_key_ctrlseq.rs`.
pub fn ctrl_seq(
    text: &str,
    unshifted: Option<char>,
    physical: Option<char>,
    mods: Mods,
) -> Option<u8> {
    if !mods.contains(Mods::CTRL) {
        return None;
    }
    // Alt does not decide whether this is a control sequence; the ESC prefix
    // is handled separately.
    let mut unset = mods - Mods::ALT;

    let bytes = text.as_bytes();
    let mut ch: u8 = if bytes.len() == 1 {
        bytes[0]
    } else {
        // A layout whose key types a non-ASCII character: fall back to the
        // key itself, and only when control is all that is held.
        let base = physical.or(unshifted)?;
        let byte = u8::try_from(base as u32).ok()?;
        if unset != Mods::CTRL {
            return None;
        }
        byte
    };

    // Shift outside the letter range does not block a control sequence, so
    // `ctrl+shift+-` still gives 0x1F. `@` is fixterms' awkward exception.
    if unset.contains(Mods::SHIFT) && !ch.is_ascii_uppercase() && ch != b'@' {
        unset -= Mods::SHIFT;
    }

    // An upper-case letter is mapped through the unshifted key, which is how
    // caps lock ends up meaning the same as no shift at all.
    //
    // Upstream relies on the host always reporting an unshifted codepoint.
    // Ours are not all able to -- the scripting and intent paths have only
    // the character -- so a bare upper-case letter falls back to its own
    // lower case rather than silently losing `ctrl+A`.
    if ch.is_ascii_uppercase() {
        ch = match unshifted.and_then(|base| u8::try_from(base as u32).ok()) {
            Some(byte) => byte,
            None => ch.to_ascii_lowercase(),
        };
    }

    if unset != Mods::CTRL {
        return None;
    }

    // Kitty's table. `i`, `m` and `[` are deliberately absent: fixterms says
    // they go out as CSI u so they stay distinguishable from tab, enter and
    // escape.
    Some(match ch {
        b' ' => 0,
        b'/' => 31,
        b'0' => 48,
        b'1' => 49,
        b'2' => 0,
        b'3' => 27,
        b'4' => 28,
        b'5' => 29,
        b'6' => 30,
        b'7' => 31,
        b'8' => 127,
        b'9' => 57,
        b'?' => 127,
        b'@' => 0,
        b'\\' => 28,
        b']' => 29,
        b'^' => 30,
        b'_' => 31,
        b'~' => 30,
        b'a'..=b'h' => ch - b'a' + 1,
        b'j'..=b'l' => ch - b'a' + 1,
        b'n'..=b'z' => ch - b'a' + 1,
        _ => return None,
    })
}

/// xterm's "modifyOtherKeys" state 2, ported from upstream's inline block
/// in `legacy()`. `None` when the combination doesn't need modifying (the
/// caller falls through to its normal encoding).
fn modify_other_keys(c: char, mods: Mods, macos_option_as_alt: OptionAsAlt) -> Option<Vec<u8>> {
    let mut mods_binding = mods.binding();
    // The macOS option key only counts as a real modifier here when the
    // config says it should be treated as alt; otherwise it produced a
    // composed character and isn't "used" for this purpose. We don't track
    // which physical side (left/right) was held, so Left/Right both count
    // as if the option key in question was the held one.
    if !matches!(
        macos_option_as_alt,
        OptionAsAlt::True | OptionAsAlt::Left | OptionAsAlt::Right
    ) {
        mods_binding -= Mods::ALT;
    }

    let cp = c as u32;
    let should_modify = (0x40..=0x7F).contains(&cp)
        || !(mods_binding - Mods::SHIFT).is_empty()
        || c == ' ';
    if !should_modify {
        return None;
    }

    let code = 1 + mods_binding.bits();
    Some(format!("\x1b[27;{code};{cp}~").into_bytes())
}

/// The fixterms CSI u fallback for ctrl+key combinations `ctrl_seq` refuses
/// (see its doc comment): letters with no C0 byte of their own, and
/// ctrl+shift+letter, which must stay distinguishable from plain
/// ctrl+letter. Ported from upstream's `csiu:` block in `legacy()`.
fn fixterms_csi_u(c: char, unshifted: Option<char>, mods: Mods) -> Vec<u8> {
    // Kitty-style behavior (which upstream deliberately follows over strict
    // fixterms): a shifted uppercase letter is lowercased here, which is
    // what lets programs detect shifted letters for keybindings.
    let fixterms_char = if c.is_ascii_uppercase() && mods.contains(Mods::SHIFT) {
        c.to_ascii_lowercase() as u32
    } else {
        c as u32
    };

    // Shift only survives into the mods field when the unshifted codepoint
    // matches what we're sending -- otherwise shift was already "used" to
    // produce this character and reporting it again would be redundant.
    let mut out_mods = mods;
    if unshifted.map(|u| u as u32) != Some(fixterms_char) {
        out_mods -= Mods::SHIFT;
    }

    let code = 1 + out_mods.binding().bits();
    format!("\x1b[{fixterms_char};{code}u").into_bytes()
}

fn encode_arrow(
    letter: char,
    config: EncodeConfig,
    mod_str: Option<String>,
) -> Vec<u8> {
    if let Some(s) = mod_str {
        format!("\x1b[1;{s}{letter}").into_bytes()
    } else if config.cursor_key_app_mode {
        format!("\x1bO{letter}").into_bytes()
    } else {
        format!("\x1b[{letter}").into_bytes()
    }
}

fn encode_tilde(code: u8, mod_str: Option<String>) -> Vec<u8> {
    if let Some(s) = mod_str {
        format!("\x1b[{code};{s}~").into_bytes()
    } else {
        format!("\x1b[{code}~").into_bytes()
    }
}

fn encode_f1_f4(letter: char, mod_str: Option<String>) -> Vec<u8> {
    if let Some(s) = mod_str {
        format!("\x1b[1;{s}{letter}").into_bytes()
    } else {
        format!("\x1bO{letter}").into_bytes()
    }
}

fn encode_ambiguous(
    codepoint: u32,
    legacy_bytes: &[u8],
    event: KeyEvent,
    config: EncodeConfig,
    disambiguate: bool,
    mod_str: Option<String>,
    // True for keys that exist to produce text -- characters, space, the
    // keypad symbols -- as opposed to the ambiguous ones this mode is
    // named for.
    text_key: bool,
) -> Vec<u8> {
    // Under "disambiguate escape codes" alone, a key that produces text is
    // still sent as that text unless it carries a modifier other than shift.
    // Escaping it anyway hands the shell `CSI 97;2u` for a shifted `a`, and
    // a shell that speaks the protocol then has to work out the text itself
    // -- fish does not, so shifted keys typed nothing at all.
    //
    // This applies only to keys whose whole purpose is text. Escape, Enter,
    // Tab and Backspace also produce bytes, but they are the ambiguous ones
    // the mode exists to disambiguate. Reporting event types or all keys as
    // escape codes turns everything into escapes, by definition.
    let report_all_keys = (config.kitty_flags & 8) != 0;
    let report_events = (config.kitty_flags & 2) != 0;
    let only_shift = (event.mods - Mods::SHIFT).is_empty();
    if disambiguate && text_key && only_shift && !report_all_keys && !report_events {
        return legacy_bytes.to_vec();
    }

    if disambiguate {
        if let Some(s) = mod_str {
            format!("\x1b[{codepoint};{s}u").into_bytes()
        } else {
            format!("\x1b[{codepoint}u").into_bytes()
        }
    } else if event.mods.contains(Mods::ALT) && config.alt_esc_prefix {
        // The alt-prefixed output is `ESC` plus exactly one byte -- not the
        // original bytes with `ESC` stuck on the front. When the key's own
        // bytes aren't a single byte (a non-ASCII character), we fall back
        // to the unshifted codepoint if it fits in one; otherwise there is
        // nothing to prefix and alt is left to do nothing rather than
        // mangling multi-byte UTF-8 with a raw `ESC` in front of it.
        let byte = if legacy_bytes.len() == 1 {
            Some(legacy_bytes[0])
        } else {
            event.unshifted.and_then(|u| u8::try_from(u as u32).ok())
        };
        match byte {
            Some(b) => vec![0x1b, b],
            None => legacy_bytes.to_vec(),
        }
    } else {
        legacy_bytes.to_vec()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn press(key: Key) -> KeyEvent {
        KeyEvent {
            key,
            mods: Mods::empty(),
            repeat: false,
            press: true,
            unshifted: None,
            physical: None,
            text: None,
            composing: false,
        }
    }

    fn press_mod(key: Key, mods: Mods) -> KeyEvent {
        KeyEvent {
            key,
            mods,
            repeat: false,
            press: true,
            unshifted: None,
            physical: None,
            text: None,
            composing: false,
        }
    }

    #[test]
    fn test_plain_letters() {
        let cfg = EncodeConfig::default();
        assert_eq!(encode(press(Key::Char('a')), cfg), b"a");
        assert_eq!(encode(press(Key::Char('Z')), cfg), b"Z");
        assert_eq!(encode(press(Key::Char('ñ')), cfg), "ñ".as_bytes());
    }

    #[test]
    fn test_ctrl_codes() {
        let cfg = EncodeConfig::default();
        assert_eq!(encode(press_mod(Key::Char('a'), Mods::CTRL), cfg), b"\x01");
        assert_eq!(encode(press_mod(Key::Char('A'), Mods::CTRL), cfg), b"\x01");
        assert_eq!(encode(press_mod(Key::Char('z'), Mods::CTRL), cfg), b"\x1a");
        assert_eq!(encode(press_mod(Key::Char('@'), Mods::CTRL), cfg), b"\x00");
        assert_eq!(encode(press_mod(Key::Char('_'), Mods::CTRL), cfg), b"\x1f");
        assert_eq!(encode(press_mod(Key::Space, Mods::CTRL), cfg), b"\x00");
    }

    #[test]
    fn test_alt_prefixing() {
        let cfg = EncodeConfig { alt_esc_prefix: true, ..Default::default() };

        assert_eq!(encode(press_mod(Key::Char('a'), Mods::ALT), cfg), b"\x1ba");
        assert_eq!(
            encode(press_mod(Key::Char('a'), Mods::CTRL | Mods::ALT), cfg),
            b"\x1b\x01"
        );
        assert_eq!(encode(press_mod(Key::Enter, Mods::ALT), cfg), b"\x1b\r");

        let cfg_no_alt = EncodeConfig { alt_esc_prefix: false, ..Default::default() };
        assert_eq!(
            encode(press_mod(Key::Char('a'), Mods::ALT), cfg_no_alt),
            b"a"
        );
    }

    #[test]
    fn test_named_keys() {
        let cfg = EncodeConfig::default();
        assert_eq!(encode(press(Key::Enter), cfg), b"\r");
        assert_eq!(encode(press(Key::Tab), cfg), b"\t");
        assert_eq!(encode(press_mod(Key::Tab, Mods::SHIFT), cfg), b"\x1b[Z");
        assert_eq!(encode(press(Key::Backspace), cfg), b"\x7f");
        assert_eq!(
            encode(press_mod(Key::Backspace, Mods::CTRL), cfg),
            b"\x08"
        );
        assert_eq!(encode(press(Key::Escape), cfg), b"\x1b");
        assert_eq!(encode(press(Key::Space), cfg), b" ");
    }

    #[test]
    fn test_arrows_normal_and_app_mode() {
        let cfg_norm = EncodeConfig { cursor_key_app_mode: false, ..Default::default() };
        assert_eq!(encode(press(Key::Up), cfg_norm), b"\x1b[A");
        assert_eq!(encode(press(Key::Down), cfg_norm), b"\x1b[B");
        assert_eq!(encode(press(Key::Right), cfg_norm), b"\x1b[C");
        assert_eq!(encode(press(Key::Left), cfg_norm), b"\x1b[D");

        let cfg_app = EncodeConfig { cursor_key_app_mode: true, ..Default::default() };
        assert_eq!(encode(press(Key::Up), cfg_app), b"\x1bOA");
        assert_eq!(encode(press(Key::Down), cfg_app), b"\x1bOB");
        assert_eq!(encode(press(Key::Right), cfg_app), b"\x1bOC");
        assert_eq!(encode(press(Key::Left), cfg_app), b"\x1bOD");
    }

    #[test]
    fn test_arrows_modifiers() {
        let cfg = EncodeConfig::default();
        // {m} = 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0) + (super?8:0)
        assert_eq!(encode(press_mod(Key::Up, Mods::SHIFT), cfg), b"\x1b[1;2A");
        assert_eq!(encode(press_mod(Key::Up, Mods::ALT), cfg), b"\x1b[1;3A");
        assert_eq!(encode(press_mod(Key::Up, Mods::CTRL), cfg), b"\x1b[1;5A");
        assert_eq!(encode(press_mod(Key::Up, Mods::SUPER), cfg), b"\x1b[1;9A");

        // Combination: SHIFT + CTRL = 1 + 1 + 4 = 6
        assert_eq!(
            encode(press_mod(Key::Up, Mods::SHIFT | Mods::CTRL), cfg),
            b"\x1b[1;6A"
        );
        // All mods: 1 + 1 + 2 + 4 + 8 = 16
        assert_eq!(
            encode(
                press_mod(
                    Key::Up,
                    Mods::SHIFT | Mods::ALT | Mods::CTRL | Mods::SUPER
                ),
                cfg
            ),
            b"\x1b[1;16A"
        );
    }

    #[test]
    fn test_home_end() {
        let mut cfg = EncodeConfig::default();
        assert_eq!(encode(press(Key::Home), cfg), b"\x1b[H");
        assert_eq!(encode(press(Key::End), cfg), b"\x1b[F");

        cfg.cursor_key_app_mode = true;
        assert_eq!(encode(press(Key::Home), cfg), b"\x1bOH");
        assert_eq!(encode(press(Key::End), cfg), b"\x1bOF");

        assert_eq!(encode(press_mod(Key::Home, Mods::CTRL), cfg), b"\x1b[1;5H");
        assert_eq!(encode(press_mod(Key::End, Mods::ALT), cfg), b"\x1b[1;3F");
    }

    #[test]
    fn test_insert_delete_page() {
        let cfg = EncodeConfig::default();
        assert_eq!(encode(press(Key::Insert), cfg), b"\x1b[2~");
        assert_eq!(encode(press(Key::Delete), cfg), b"\x1b[3~");
        assert_eq!(encode(press(Key::PageUp), cfg), b"\x1b[5~");
        assert_eq!(encode(press(Key::PageDown), cfg), b"\x1b[6~");

        assert_eq!(
            encode(press_mod(Key::Insert, Mods::SHIFT), cfg),
            b"\x1b[2;2~"
        );
        assert_eq!(
            encode(press_mod(Key::Delete, Mods::CTRL), cfg),
            b"\x1b[3;5~"
        );
    }

    #[test]
    fn test_f1_f4() {
        let cfg = EncodeConfig::default();
        assert_eq!(encode(press(Key::F1), cfg), b"\x1bOP");
        assert_eq!(encode(press(Key::F2), cfg), b"\x1bOQ");
        // F3 is the one named function key with no SS3 letter of its own --
        // it shares Enter's code (13) and the tilde form instead (upstream's
        // function-key table; see also `kitty_entry`).
        assert_eq!(encode(press(Key::F3), cfg), b"\x1b[13~");
        assert_eq!(encode(press(Key::F4), cfg), b"\x1bOS");

        assert_eq!(encode(press_mod(Key::F1, Mods::ALT), cfg), b"\x1b[1;3P");
        assert_eq!(encode(press_mod(Key::F3, Mods::CTRL), cfg), b"\x1b[13;5~");
        assert_eq!(encode(press_mod(Key::F4, Mods::CTRL), cfg), b"\x1b[1;5S");
    }

    #[test]
    fn test_f5_f12() {
        let cfg = EncodeConfig::default();
        assert_eq!(encode(press(Key::F5), cfg), b"\x1b[15~");
        assert_eq!(encode(press(Key::F12), cfg), b"\x1b[24~");

        assert_eq!(encode(press_mod(Key::F5, Mods::CTRL), cfg), b"\x1b[15;5~");
        assert_eq!(
            encode(press_mod(Key::F12, Mods::SHIFT), cfg),
            b"\x1b[24;2~"
        );
    }

    #[test]
    fn test_keypad() {
        let mut cfg = EncodeConfig { keypad_app_mode: false, ..Default::default() };
        assert_eq!(encode(press(Key::KeypadEnter), cfg), b"\r");
        assert_eq!(encode(press(Key::KeypadPlus), cfg), b"+");
        assert_eq!(encode(press(Key::KeypadMinus), cfg), b"-");
        assert_eq!(encode(press(Key::KeypadMultiply), cfg), b"*");
        assert_eq!(encode(press(Key::KeypadDivide), cfg), b"/");

        cfg.keypad_app_mode = true;
        assert_eq!(encode(press(Key::KeypadEnter), cfg), b"\x1bOM");
        assert_eq!(encode(press(Key::KeypadPlus), cfg), b"\x1bOk");
        assert_eq!(encode(press(Key::KeypadMinus), cfg), b"\x1bOm");
        assert_eq!(encode(press(Key::KeypadMultiply), cfg), b"\x1bOj");
        assert_eq!(encode(press(Key::KeypadDivide), cfg), b"\x1bOo");
    }

    #[test]
    fn test_kitty_csi_u_disambiguate() {
        let cfg = EncodeConfig { kitty_flags: 1, ..Default::default() }; // DISAMBIGUATE

        assert_eq!(encode(press(Key::Escape), cfg), b"\x1b[27u");
        // Enter/Tab/Backspace keep their legacy bytes under disambiguate
        // alone (upstream "kitty: enter, backspace, tab"): the mode exists
        // to disambiguate escape sequences from typed text, and these three
        // still work as `reset` after a crashed program leaves the mode set.
        assert_eq!(encode(press(Key::Enter), cfg), b"\r");
        // Upstream's "kitty: plain text": with only disambiguate, a key
        // whose purpose is text sends that text. Shift alone does not
        // change that -- shift is how you type a capital.
        assert_eq!(encode(press(Key::Char('a')), cfg), b"a");
        assert_eq!(encode(press_mod(Key::Char('A'), Mods::SHIFT), cfg), b"A");
        assert_eq!(
            encode(press_mod(Key::Tab, Mods::SHIFT), cfg),
            b"\x1b[9;2u"
        );
    }

    #[test]
    fn test_kitty_event_types() {
        let cfg = EncodeConfig { kitty_flags: 2, ..Default::default() }; // REPORT_EVENT_TYPES

        // Up has no committed text, so (unlike a plain character key) it
        // never takes the plain-text passthrough shortcut and cleanly
        // demonstrates event-type reporting. Kitty omits the modifier/event
        // section entirely for a plain press with no modifiers (upstream's
        // `KittySequence.encodeFull`/`encodeSpecial`: the section is only
        // written when the event is repeat/release, or `mods > 1`).
        assert_eq!(encode(press(Key::Up), cfg), b"\x1b[A");

        let mut repeat_up = press(Key::Up);
        repeat_up.repeat = true;
        assert_eq!(encode(repeat_up, cfg), b"\x1b[1;1:2A");

        let mut release_up = press(Key::Up);
        release_up.press = false;
        assert_eq!(encode(release_up, cfg), b"\x1b[1;1:3A");

        // A character key still reports its event type once a real modifier
        // forces the mods/event section to appear. `unshifted` must be set
        // for a plain letter to get a table entry at all -- like upstream,
        // a bare `Key::Char` with no unshifted codepoint has nothing to
        // derive one from and just sends its text verbatim.
        let mut release_a = press_mod(Key::Char('a'), Mods::SHIFT);
        release_a.unshifted = Some('a');
        release_a.press = false;
        assert_eq!(encode(release_a, cfg), b"\x1b[97;2:3u");
    }

    #[test]
    fn test_legacy_release_yields_empty() {
        let cfg = EncodeConfig::default();
        let mut release_a = press(Key::Char('a'));
        release_a.press = false;
        assert_eq!(encode(release_a, cfg), Vec::<u8>::new());
    }
}
