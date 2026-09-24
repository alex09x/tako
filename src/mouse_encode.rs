#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseButton {
    Left,
    Middle,
    Right,
    WheelUp,
    WheelDown,
    WheelLeft,
    WheelRight,
    None,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseAction {
    Press,
    Release,
    Motion,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct MouseMods {
    pub shift: bool,
    pub alt: bool,
    pub ctrl: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct MouseEvent {
    pub button: MouseButton,
    pub action: MouseAction,
    pub mods: MouseMods,
    pub col: u32,
    pub row: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MouseEncoding {
    X10,
    Utf8,
    Sgr,
}

pub fn encode(event: MouseEvent, encoding: MouseEncoding) -> Option<Vec<u8>> {
    let is_wheel = matches!(
        event.button,
        MouseButton::WheelUp
            | MouseButton::WheelDown
            | MouseButton::WheelLeft
            | MouseButton::WheelRight
    );

    if is_wheel && event.action == MouseAction::Release {
        return None;
    }

    let mut mods_val = 0u32;
    if event.mods.shift {
        mods_val |= 4;
    }
    if event.mods.alt {
        mods_val |= 8;
    }
    if event.mods.ctrl {
        mods_val |= 16;
    }

    let motion_val = if event.action == MouseAction::Motion {
        32
    } else {
        0
    };

    match encoding {
        MouseEncoding::X10 => {
            let base_button = if event.action == MouseAction::Release {
                3
            } else {
                match event.button {
                    MouseButton::Left => 0,
                    MouseButton::Middle => 1,
                    MouseButton::Right => 2,
                    MouseButton::None => 3,
                    MouseButton::WheelUp => 64,
                    MouseButton::WheelDown => 65,
                    MouseButton::WheelLeft => 66,
                    MouseButton::WheelRight => 67,
                }
            };

            let button_val = base_button + mods_val + motion_val;
            let button_byte = button_val.checked_add(32)?;
            if button_byte > 255 {
                return None;
            }

            if event.col > 223 || event.row > 223 {
                return None;
            }

            let col_byte = (event.col + 1 + 32) as u8;
            let row_byte = (event.row + 1 + 32) as u8;

            let mut out = Vec::with_capacity(6);
            out.extend_from_slice(b"\x1b[M");
            out.push(button_byte as u8);
            out.push(col_byte);
            out.push(row_byte);
            Some(out)
        }
        MouseEncoding::Utf8 => {
            let base_button = if event.action == MouseAction::Release {
                3
            } else {
                match event.button {
                    MouseButton::Left => 0,
                    MouseButton::Middle => 1,
                    MouseButton::Right => 2,
                    MouseButton::None => 3,
                    MouseButton::WheelUp => 64,
                    MouseButton::WheelDown => 65,
                    MouseButton::WheelLeft => 66,
                    MouseButton::WheelRight => 67,
                }
            };

            let button_val = base_button + mods_val + motion_val;
            let button_byte = button_val.checked_add(32)?;
            if button_byte > 255 {
                return None;
            }

            let col_code = event.col.checked_add(1)?.checked_add(32)?;
            let row_code = event.row.checked_add(1)?.checked_add(32)?;

            let col_char = char::from_u32(col_code)?;
            let row_char = char::from_u32(row_code)?;

            let mut out = Vec::with_capacity(6);
            out.extend_from_slice(b"\x1b[M");
            out.push(button_byte as u8);

            let mut buf = [0u8; 4];
            out.extend_from_slice(col_char.encode_utf8(&mut buf).as_bytes());
            out.extend_from_slice(row_char.encode_utf8(&mut buf).as_bytes());
            Some(out)
        }
        MouseEncoding::Sgr => {
            let base_button = match event.button {
                MouseButton::Left => 0,
                MouseButton::Middle => 1,
                MouseButton::Right => 2,
                MouseButton::None => 3,
                MouseButton::WheelUp => 64,
                MouseButton::WheelDown => 65,
                MouseButton::WheelLeft => 66,
                MouseButton::WheelRight => 67,
            };

            let button_val = base_button + mods_val + motion_val;
            let col_1based = event.col.checked_add(1)?;
            let row_1based = event.row.checked_add(1)?;
            let final_char = if event.action == MouseAction::Release {
                'm'
            } else {
                'M'
            };

            let s = format!("\x1b[<{button_val};{col_1based};{row_1based}{final_char}");
            Some(s.into_bytes())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_left_press_at_origin() {
        let event = MouseEvent {
            button: MouseButton::Left,
            action: MouseAction::Press,
            mods: MouseMods::default(),
            col: 0,
            row: 0,
        };

        assert_eq!(
            encode(event, MouseEncoding::X10),
            Some(b"\x1b[M !!".to_vec())
        );
        assert_eq!(
            encode(event, MouseEncoding::Utf8),
            Some(b"\x1b[M !!".to_vec())
        );
        assert_eq!(
            encode(event, MouseEncoding::Sgr),
            Some(b"\x1b[<0;1;1M".to_vec())
        );
    }

    #[test]
    fn test_large_coordinate_x10_vs_sgr() {
        let event = MouseEvent {
            button: MouseButton::Left,
            action: MouseAction::Press,
            mods: MouseMods::default(),
            col: 300,
            row: 300,
        };

        assert_eq!(encode(event, MouseEncoding::X10), None);
        assert_eq!(
            encode(event, MouseEncoding::Sgr),
            Some(b"\x1b[<0;301;301M".to_vec())
        );
    }

    #[test]
    fn test_release_x10_vs_sgr() {
        let event = MouseEvent {
            button: MouseButton::Left,
            action: MouseAction::Release,
            mods: MouseMods::default(),
            col: 5,
            row: 10,
        };

        assert_eq!(
            encode(event, MouseEncoding::X10),
            Some(b"\x1b[M#&+".to_vec())
        );
        assert_eq!(
            encode(event, MouseEncoding::Sgr),
            Some(b"\x1b[<0;6;11m".to_vec())
        );
    }

    #[test]
    fn test_modifiers() {
        let event_shift = MouseEvent {
            button: MouseButton::Left,
            action: MouseAction::Press,
            mods: MouseMods {
                shift: true,
                alt: false,
                ctrl: false,
            },
            col: 0,
            row: 0,
        };
        assert_eq!(
            encode(event_shift, MouseEncoding::Sgr),
            Some(b"\x1b[<4;1;1M".to_vec())
        );

        let event_alt = MouseEvent {
            button: MouseButton::Left,
            action: MouseAction::Press,
            mods: MouseMods {
                shift: false,
                alt: true,
                ctrl: false,
            },
            col: 0,
            row: 0,
        };
        assert_eq!(
            encode(event_alt, MouseEncoding::Sgr),
            Some(b"\x1b[<8;1;1M".to_vec())
        );

        let event_ctrl = MouseEvent {
            button: MouseButton::Left,
            action: MouseAction::Press,
            mods: MouseMods {
                shift: false,
                alt: false,
                ctrl: true,
            },
            col: 0,
            row: 0,
        };
        assert_eq!(
            encode(event_ctrl, MouseEncoding::Sgr),
            Some(b"\x1b[<16;1;1M".to_vec())
        );

        let event_combo = MouseEvent {
            button: MouseButton::Left,
            action: MouseAction::Press,
            mods: MouseMods {
                shift: true,
                alt: true,
                ctrl: true,
            },
            col: 0,
            row: 0,
        };
        assert_eq!(
            encode(event_combo, MouseEncoding::Sgr),
            Some(b"\x1b[<28;1;1M".to_vec())
        );
    }

    #[test]
    fn test_motion() {
        let event_button_motion = MouseEvent {
            button: MouseButton::Left,
            action: MouseAction::Motion,
            mods: MouseMods::default(),
            col: 0,
            row: 0,
        };
        assert_eq!(
            encode(event_button_motion, MouseEncoding::Sgr),
            Some(b"\x1b[<32;1;1M".to_vec())
        );

        let event_no_button_motion = MouseEvent {
            button: MouseButton::None,
            action: MouseAction::Motion,
            mods: MouseMods::default(),
            col: 0,
            row: 0,
        };
        assert_eq!(
            encode(event_no_button_motion, MouseEncoding::Sgr),
            Some(b"\x1b[<35;1;1M".to_vec())
        );
    }

    #[test]
    fn test_wheel_directions_and_release() {
        let wheels = [
            (MouseButton::WheelUp, 64),
            (MouseButton::WheelDown, 65),
            (MouseButton::WheelLeft, 66),
            (MouseButton::WheelRight, 67),
        ];

        for (btn, num) in wheels {
            let press_event = MouseEvent {
                button: btn,
                action: MouseAction::Press,
                mods: MouseMods::default(),
                col: 0,
                row: 0,
            };
            let expected_sgr = format!("\x1b[<{num};1;1M").into_bytes();
            assert_eq!(
                encode(press_event, MouseEncoding::Sgr),
                Some(expected_sgr)
            );

            let release_event = MouseEvent {
                button: btn,
                action: MouseAction::Release,
                mods: MouseMods::default(),
                col: 0,
                row: 0,
            };
            assert_eq!(encode(release_event, MouseEncoding::X10), None);
            assert_eq!(encode(release_event, MouseEncoding::Utf8), None);
            assert_eq!(encode(release_event, MouseEncoding::Sgr), None);
        }
    }

    #[test]
    fn test_utf8_multibyte_coordinate() {
        let event = MouseEvent {
            button: MouseButton::Left,
            action: MouseAction::Press,
            mods: MouseMods::default(),
            col: 100,
            row: 0,
        };

        let encoded = encode(event, MouseEncoding::Utf8).expect("utf8 encode failed");
        assert_eq!(encoded.len(), 7);
        assert_eq!(&encoded[0..4], b"\x1b[M ");
        assert_eq!(&encoded[4..6], &[0xC2, 0x85]);
        assert_eq!(&encoded[6..7], b"!");
    }
}
