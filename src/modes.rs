#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum MouseTracking {
    Off,
    Normal,
    ButtonEvent,
    AnyEvent,
}

pub struct TerminalModes {
    pub autowrap: bool,             // DECAWM, mode 7, default true
    pub origin_mode: bool,          // DECOM, mode 6, default false
    pub cursor_key_app_mode: bool,  // DECCKM, mode 1, default false
    pub mouse_tracking: MouseTracking, // default Off
    pub mouse_utf8: bool,           // mode 1005, default false
    pub mouse_sgr: bool,            // mode 1006, default false
    pub focus_events: bool,         // mode 1004, default false
    pub bracketed_paste: bool,      // mode 2004, default false
    pub insert: bool,               // IRM, ANSI mode 4 (CSI 4 h/l), default false
    pub linefeed_mode: bool,        // LNM, ANSI mode 20: LF implies CR, default false
    pub reverse_wrap: bool,         // DEC mode 45, default false
    pub reverse_wrap_extended: bool, // xterm mode 1045, default false
    pub left_right_margin_mode: bool,
    /// Mode 1007: wheel events scroll the alternate screen as arrow keys.
    pub alternate_scroll: bool, // DECLRMM, mode 69: CSI s sets margins, default false
    /// Mode 2026 (Synchronized Output): while set, a redrawing app is mid
    /// frame. A host must hold off repainting until it's reset, or it can
    /// show a real, partially-applied frame the app never intended to be
    /// visible -- not a rendering race, an unfinished one. See
    /// `Terminal::take_damage`, which is what actually enforces this.
    pub synchronized_output: bool, // default false
    /// XTSHIFTESCAPE (`CSI > Ps s`): whether the program asked for Shift to
    /// be reported with mouse events (`Some(true)`, Ps 1) or left to the
    /// terminal to extend a selection (`Some(false)`, Ps 0). `None` until a
    /// program asks; the host's `mouse-shift-capture` decides what that means
    /// and whether the request counts at all.
    pub shift_capture: Option<bool>,
    /// Mode 2027 (grapheme clustering): a cluster's width follows its
    /// presentation (an emoji sequence is two columns) rather than the sum
    /// of per-codepoint widths. Its default comes from the host's
    /// grapheme-width-method; see `Terminal::set_grapheme_width_method`.
    pub grapheme_cluster: bool,
}

impl TerminalModes {
    pub fn new() -> Self {
        Self {
            autowrap: true,
            origin_mode: false,
            cursor_key_app_mode: false,
            mouse_tracking: MouseTracking::Off,
            mouse_utf8: false,
            mouse_sgr: false,
            focus_events: false,
            bracketed_paste: false,
            insert: false,
            linefeed_mode: false,
            reverse_wrap: false,
            reverse_wrap_extended: false,
            left_right_margin_mode: false,
            alternate_scroll: true,
            synchronized_output: false,
            shift_capture: None,
            grapheme_cluster: true,
        }
    }

    pub fn apply_private_mode(&mut self, code: u16, set: bool) {
        match code {
            1 => self.cursor_key_app_mode = set,
            6 => self.origin_mode = set,
            7 => self.autowrap = set,
            1000 => {
                self.mouse_tracking = if set {
                    MouseTracking::Normal
                } else {
                    MouseTracking::Off
                };
            }
            1002 => {
                self.mouse_tracking = if set {
                    MouseTracking::ButtonEvent
                } else {
                    MouseTracking::Off
                };
            }
            1003 => {
                self.mouse_tracking = if set {
                    MouseTracking::AnyEvent
                } else {
                    MouseTracking::Off
                };
            }
            1004 => self.focus_events = set,
            1005 => self.mouse_utf8 = set,
            1006 => self.mouse_sgr = set,
            2004 => self.bracketed_paste = set,
            45 => self.reverse_wrap = set,
            1045 => self.reverse_wrap_extended = set,
            69 => self.left_right_margin_mode = set,
            1007 => self.alternate_scroll = set,
            2026 => self.synchronized_output = set,
            2027 => self.grapheme_cluster = set,
            _ => {}
        }
    }
}

impl Default for TerminalModes {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_defaults() {
        let modes = TerminalModes::new();
        assert!(modes.autowrap);
        assert!(!modes.origin_mode);
        assert!(!modes.cursor_key_app_mode);
        assert_eq!(modes.mouse_tracking, MouseTracking::Off);
        assert!(!modes.mouse_utf8);
        assert!(!modes.mouse_sgr);
        assert!(!modes.focus_events);
        assert!(!modes.bracketed_paste);

        let default_modes = TerminalModes::default();
        assert_eq!(default_modes.autowrap, modes.autowrap);
        assert_eq!(default_modes.origin_mode, modes.origin_mode);
        assert_eq!(default_modes.cursor_key_app_mode, modes.cursor_key_app_mode);
        assert_eq!(default_modes.mouse_tracking, modes.mouse_tracking);
        assert_eq!(default_modes.mouse_utf8, modes.mouse_utf8);
        assert_eq!(default_modes.mouse_sgr, modes.mouse_sgr);
        assert_eq!(default_modes.focus_events, modes.focus_events);
        assert_eq!(default_modes.bracketed_paste, modes.bracketed_paste);
    }

    #[test]
    fn test_apply_private_mode_mapped_codes() {
        let mut modes = TerminalModes::new();

        // Code 1
        modes.apply_private_mode(1, true);
        assert!(modes.cursor_key_app_mode);
        modes.apply_private_mode(1, false);
        assert!(!modes.cursor_key_app_mode);

        // Code 6
        modes.apply_private_mode(6, true);
        assert!(modes.origin_mode);
        modes.apply_private_mode(6, false);
        assert!(!modes.origin_mode);

        // Code 7 (default true)
        modes.apply_private_mode(7, false);
        assert!(!modes.autowrap);
        modes.apply_private_mode(7, true);
        assert!(modes.autowrap);

        // Code 1000
        modes.apply_private_mode(1000, true);
        assert_eq!(modes.mouse_tracking, MouseTracking::Normal);
        modes.apply_private_mode(1000, false);
        assert_eq!(modes.mouse_tracking, MouseTracking::Off);

        // Code 1002
        modes.apply_private_mode(1002, true);
        assert_eq!(modes.mouse_tracking, MouseTracking::ButtonEvent);
        modes.apply_private_mode(1002, false);
        assert_eq!(modes.mouse_tracking, MouseTracking::Off);

        // Code 1003
        modes.apply_private_mode(1003, true);
        assert_eq!(modes.mouse_tracking, MouseTracking::AnyEvent);
        modes.apply_private_mode(1003, false);
        assert_eq!(modes.mouse_tracking, MouseTracking::Off);

        // Code 1004
        modes.apply_private_mode(1004, true);
        assert!(modes.focus_events);
        modes.apply_private_mode(1004, false);
        assert!(!modes.focus_events);

        // Code 1005
        modes.apply_private_mode(1005, true);
        assert!(modes.mouse_utf8);
        modes.apply_private_mode(1005, false);
        assert!(!modes.mouse_utf8);

        // Code 1006
        modes.apply_private_mode(1006, true);
        assert!(modes.mouse_sgr);
        modes.apply_private_mode(1006, false);
        assert!(!modes.mouse_sgr);

        // Code 2004
        modes.apply_private_mode(2004, true);
        assert!(modes.bracketed_paste);
        modes.apply_private_mode(2004, false);
        assert!(!modes.bracketed_paste);

        // Code 1007 (default true)
        assert!(modes.alternate_scroll);
        modes.apply_private_mode(1007, false);
        assert!(!modes.alternate_scroll);
        modes.apply_private_mode(1007, true);
        assert!(modes.alternate_scroll);
    }

    #[test]
    fn test_mouse_tracking_switching() {
        let mut modes = TerminalModes::new();

        modes.apply_private_mode(1000, true);
        assert_eq!(modes.mouse_tracking, MouseTracking::Normal);

        modes.apply_private_mode(1002, true);
        assert_eq!(modes.mouse_tracking, MouseTracking::ButtonEvent);

        modes.apply_private_mode(1003, true);
        assert_eq!(modes.mouse_tracking, MouseTracking::AnyEvent);

        modes.apply_private_mode(1000, true);
        assert_eq!(modes.mouse_tracking, MouseTracking::Normal);

        modes.apply_private_mode(1003, false);
        assert_eq!(modes.mouse_tracking, MouseTracking::Off);
    }

    #[test]
    fn test_unrecognized_code() {
        let mut modes = TerminalModes::new();
        modes.apply_private_mode(1, true);
        modes.apply_private_mode(1004, true);

        // Unrecognized code 9999
        modes.apply_private_mode(9999, true);
        assert!(modes.cursor_key_app_mode);
        assert!(modes.focus_events);
        assert!(modes.autowrap);
        assert!(!modes.origin_mode);
        assert_eq!(modes.mouse_tracking, MouseTracking::Off);

        modes.apply_private_mode(9999, false);
        assert!(modes.cursor_key_app_mode);
        assert!(modes.focus_events);
        assert!(modes.autowrap);
        assert!(!modes.origin_mode);
        assert_eq!(modes.mouse_tracking, MouseTracking::Off);
    }
}
