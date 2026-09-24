pub struct Palette {
    /// Live values: what OSC 4 sets and OSC 4's query reports.
    colors: [(u8, u8, u8); 256],
    /// Host-configured base, via `Terminal::set_base_colors`. Starts as the
    /// built-in defaults and is what OSC 104 restores entries to.
    base: [(u8, u8, u8); 256],
    /// Whether a program has set this index via OSC 4 since the last reset
    /// (OSC 104 or RIS). While false, a base change updates the live value
    /// immediately; once true, the program's explicit color sticks until
    /// reset.
    overridden: [bool; 256],
    /// Host base for the OSC 10/11/12 default fg/bg/cursor colors. Kept
    /// alongside the indexed palette base so a host's whole theme -- 256
    /// indexed entries plus fg/bg/cursor -- lives in one place with the same
    /// base/override bookkeeping. `None` means the host hasn't configured
    /// that slot, matching the engine's behavior before any base was set.
    base_fg: Option<(u8, u8, u8)>,
    base_bg: Option<(u8, u8, u8)>,
    base_cursor: Option<(u8, u8, u8)>,
    /// Whether a program has set the fg/bg/cursor slot via OSC 10/11/12
    /// since the last reset (OSC 110/111/112 or RIS).
    fg_overridden: bool,
    bg_overridden: bool,
    cursor_overridden: bool,
}

fn default_color(index: u8) -> (u8, u8, u8) {
    match index {
        // Upstream's defaults:
        // the Tomorrow Night palette, not the classic VGA one.
        0 => (0x1D, 0x1F, 0x21),
        1 => (0xCC, 0x66, 0x66),
        2 => (0xB5, 0xBD, 0x68),
        3 => (0xF0, 0xC6, 0x74),
        4 => (0x81, 0xA2, 0xBE),
        5 => (0xB2, 0x94, 0xBB),
        6 => (0x8A, 0xBE, 0xB7),
        7 => (0xC5, 0xC8, 0xC6),
        8 => (0x66, 0x66, 0x66),
        9 => (0xD5, 0x4E, 0x53),
        10 => (0xB9, 0xCA, 0x4A),
        11 => (0xE7, 0xC5, 0x47),
        12 => (0x7A, 0xA6, 0xDA),
        13 => (0xC3, 0x97, 0xD8),
        14 => (0x70, 0xC0, 0xB1),
        15 => (0xEA, 0xEA, 0xEA),
        16..=231 => {
            let n = index - 16;
            let r = n / 36;
            let g = (n / 6) % 6;
            let b = n % 6;
            let map_val = |v: u8| if v == 0 { 0 } else { v * 40 + 55 };
            (map_val(r), map_val(g), map_val(b))
        }
        232..=255 => {
            let gray = 8 + (index - 232) * 10;
            (gray, gray, gray)
        }
    }
}

impl Palette {
    pub fn new() -> Self {
        let mut colors = [(0, 0, 0); 256];
        for i in 0..=255 {
            colors[i as usize] = default_color(i);
        }
        Self {
            colors,
            base: colors,
            overridden: [false; 256],
            base_fg: None,
            base_bg: None,
            base_cursor: None,
            fg_overridden: false,
            bg_overridden: false,
            cursor_overridden: false,
        }
    }

    pub fn colors(&self) -> &[(u8, u8, u8); 256] {
        &self.colors
    }

    /// Rebuilds a palette from a flat live-color snapshot (checkpoint
    /// restore). The base resets to the built-in defaults, since a
    /// checkpoint doesn't carry the host's base configuration; indices that
    /// differ from the built-in default are treated as program-overridden so
    /// a later `set_base` doesn't silently reach past a restored color.
    pub fn from_colors(colors: [(u8, u8, u8); 256]) -> Self {
        let mut base = [(0, 0, 0); 256];
        let mut overridden = [false; 256];
        for i in 0..=255 {
            base[i as usize] = default_color(i);
            overridden[i as usize] = colors[i as usize] != base[i as usize];
        }
        Self {
            colors,
            base,
            overridden,
            // A checkpoint doesn't carry the host's fg/bg/cursor base
            // configuration; restore starts unconfigured, like the engine's
            // pre-base-colors behavior.
            base_fg: None,
            base_bg: None,
            base_cursor: None,
            fg_overridden: false,
            bg_overridden: false,
            cursor_overridden: false,
        }
    }

    pub fn get(&self, index: u8) -> (u8, u8, u8) {
        self.colors[index as usize]
    }

    /// OSC 4: a program sets a palette entry. Marks it overridden so a later
    /// host base change doesn't clobber it until the program resets it.
    pub fn set(&mut self, index: u8, rgb: (u8, u8, u8)) {
        self.colors[index as usize] = rgb;
        self.overridden[index as usize] = true;
    }

    /// OSC 104 with an explicit index: restores that entry to the current
    /// base and clears its override, so a subsequent host base change
    /// reaches it again.
    pub fn reset(&mut self, index: u8) {
        self.colors[index as usize] = self.base[index as usize];
        self.overridden[index as usize] = false;
    }

    /// OSC 104 with no arguments, or RIS: restores every entry to base.
    pub fn reset_all(&mut self) {
        self.colors = self.base;
        self.overridden = [false; 256];
    }

    /// The host-configured base for `index` (built-in default until
    /// `set_base` is called).
    pub fn base(&self, index: u8) -> (u8, u8, u8) {
        self.base[index as usize]
    }

    /// Whether a program has set `index` since it was last reset.
    pub fn is_overridden(&self, index: u8) -> bool {
        self.overridden[index as usize]
    }

    /// Replaces the base and the override flags without touching the live
    /// values: a checkpoint that carries them (v3) says exactly which entries
    /// a program set, where an older one leaves [`Palette::from_colors`] to
    /// guess.
    pub fn restore_bases(&mut self, base: [(u8, u8, u8); 256], overridden: [bool; 256]) {
        self.base = base;
        self.overridden = overridden;
    }

    /// Sets the host base for `index`. Immediately updates the live value
    /// too, unless a program has explicitly overridden it via OSC 4 since
    /// the last reset.
    pub fn set_base(&mut self, index: u8, rgb: (u8, u8, u8)) {
        self.base[index as usize] = rgb;
        if !self.overridden[index as usize] {
            self.colors[index as usize] = rgb;
        }
    }

    pub fn query_response(&self, index: u8) -> String {
        let (r, g, b) = self.get(index);
        format!(
            "\x1b]4;{};rgb:{:02x}{:02x}/{:02x}{:02x}/{:02x}{:02x}\x1b\\",
            index, r, r, g, g, b, b
        )
    }

    // -- fg/bg/cursor base bookkeeping (OSC 10/11/12), mirroring the
    // indexed-palette base/override model above. --

    pub fn base_fg(&self) -> Option<(u8, u8, u8)> {
        self.base_fg
    }

    pub fn base_bg(&self) -> Option<(u8, u8, u8)> {
        self.base_bg
    }

    pub fn base_cursor(&self) -> Option<(u8, u8, u8)> {
        self.base_cursor
    }

    /// Sets the host base for fg/bg/cursor. Does not touch the live
    /// OSC 10/11/12 values -- the caller (which owns those) applies each
    /// returned base itself, for the slots `fg_overridden`/`bg_overridden`/
    /// `cursor_overridden` say aren't overridden.
    pub fn set_base_fg(&mut self, rgb: Option<(u8, u8, u8)>) {
        self.base_fg = rgb;
    }

    pub fn set_base_bg(&mut self, rgb: Option<(u8, u8, u8)>) {
        self.base_bg = rgb;
    }

    pub fn set_base_cursor(&mut self, rgb: Option<(u8, u8, u8)>) {
        self.base_cursor = rgb;
    }

    pub fn fg_overridden(&self) -> bool {
        self.fg_overridden
    }

    pub fn bg_overridden(&self) -> bool {
        self.bg_overridden
    }

    pub fn cursor_overridden(&self) -> bool {
        self.cursor_overridden
    }

    pub fn set_fg_overridden(&mut self, overridden: bool) {
        self.fg_overridden = overridden;
    }

    pub fn set_bg_overridden(&mut self, overridden: bool) {
        self.bg_overridden = overridden;
    }

    pub fn set_cursor_overridden(&mut self, overridden: bool) {
        self.cursor_overridden = overridden;
    }
}

impl Default for Palette {
    fn default() -> Self {
        Self::new()
    }
}

fn parse_group(group: &str) -> Option<u8> {
    let len = group.len();
    if !(1..=4).contains(&len) {
        return None;
    }
    let val = u16::from_str_radix(group, 16).ok()?;
    if len == 1 {
        Some((val as u8) * 17)
    } else {
        let shift = 4 * len - 8;
        Some((val >> shift) as u8)
    }
}

pub fn parse_color_spec(s: &str) -> Option<(u8, u8, u8)> {
    if s.starts_with('#') {
        let bytes = s.as_bytes();
        if bytes.len() != 7 {
            return None;
        }
        let r = u8::from_str_radix(std::str::from_utf8(&bytes[1..3]).ok()?, 16).ok()?;
        let g = u8::from_str_radix(std::str::from_utf8(&bytes[3..5]).ok()?, 16).ok()?;
        let b = u8::from_str_radix(std::str::from_utf8(&bytes[5..7]).ok()?, 16).ok()?;
        return Some((r, g, b));
    }

    if s.len() >= 4 && s.as_bytes()[..4].eq_ignore_ascii_case(b"rgb:") {
        let rest = &s[4..];
        let parts: Vec<&str> = rest.split('/').collect();
        if parts.len() != 3 {
            return None;
        }
        let len0 = parts[0].len();
        let len1 = parts[1].len();
        let len2 = parts[2].len();
        if len0 == 0 || len0 != len1 || len1 != len2 || len0 > 4 {
            return None;
        }
        let r = parse_group(parts[0])?;
        let g = parse_group(parts[1])?;
        let b = parse_group(parts[2])?;
        return Some((r, g, b));
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_palette_new_defaults() {
        let palette = Palette::new();
        // ANSI 16
        assert_eq!(palette.get(1), (0xCC, 0x66, 0x66));
        // 6x6x6 color cube
        assert_eq!(palette.get(16), (0, 0, 0));
        assert_eq!(palette.get(231), (255, 255, 255));
        // 24-step grayscale ramp
        assert_eq!(palette.get(232), (8, 8, 8));
        assert_eq!(palette.get(255), (238, 238, 238));
    }

    #[test]
    fn test_set_get_roundtrip() {
        let mut palette = Palette::new();
        palette.set(42, (12, 34, 56));
        assert_eq!(palette.get(42), (12, 34, 56));
    }

    #[test]
    fn test_reset() {
        let mut palette = Palette::new();
        palette.set(10, (1, 2, 3));
        palette.set(20, (4, 5, 6));

        palette.reset(10);
        assert_eq!(palette.get(10), (0xB9, 0xCA, 0x4A)); // default for 10
        assert_eq!(palette.get(20), (4, 5, 6)); // untouched
    }

    #[test]
    fn test_reset_all() {
        let mut palette = Palette::new();
        palette.set(10, (1, 2, 3));
        palette.set(20, (4, 5, 6));
        palette.set(200, (7, 8, 9));

        palette.reset_all();
        let default_p = Palette::new();
        for i in 0..=255 {
            assert_eq!(palette.get(i), default_p.get(i));
        }
    }

    #[test]
    fn test_query_response() {
        let palette = Palette::new();
        // index 1: (0xCC, 0x66, 0x66) - tests channel 0
        assert_eq!(
            palette.query_response(1),
            "\x1b]4;1;rgb:cccc/6666/6666\x1b\\"
        );
        // index 231: (255, 255, 255) - tests channel 255
        assert_eq!(
            palette.query_response(231),
            "\x1b]4;231;rgb:ffff/ffff/ffff\x1b\\"
        );
    }

    #[test]
    fn test_parse_color_spec_valid() {
        let expected = (255, 128, 0);
        assert_eq!(parse_color_spec("#ff8000"), Some(expected));
        assert_eq!(parse_color_spec("#FF8000"), Some(expected));
        assert_eq!(parse_color_spec("rgb:ff/80/00"), Some(expected));
        assert_eq!(parse_color_spec("RGB:ff/80/00"), Some(expected));
        assert_eq!(parse_color_spec("rgb:ffff/8080/0000"), Some(expected));

        // 1-digit test
        assert_eq!(parse_color_spec("rgb:f/8/0"), Some((255, 136, 0)));
    }

    #[test]
    fn test_parse_color_spec_malformed() {
        // wrong prefix
        assert_eq!(parse_color_spec("xyz:ff/80/00"), None);
        assert_eq!(parse_color_spec("ff8000"), None);
        assert_eq!(parse_color_spec("#ff80000"), None);

        // wrong digit count
        assert_eq!(parse_color_spec("rgb:f/8/00"), None);
        assert_eq!(parse_color_spec("#fff"), None);
        assert_eq!(parse_color_spec("rgb:fffff/80800/00000"), None);

        // non-hex characters
        assert_eq!(parse_color_spec("rgb:fg/80/00"), None);
        assert_eq!(parse_color_spec("#ff800g"), None);

        // mismatched group lengths
        assert_eq!(parse_color_spec("rgb:ff/800/00"), None);

        // empty / unicode / malformed
        assert_eq!(parse_color_spec(""), None);
        assert_eq!(parse_color_spec("#"), None);
        assert_eq!(parse_color_spec("rgb:"), None);
        assert_eq!(parse_color_spec("rgb:///"), None);
        assert_eq!(parse_color_spec("\u{1f600}"), None);
        assert_eq!(parse_color_spec("#\u{1f600}"), None);
    }
}
