#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CursorShape {
    Block,
    Underline,
    Bar,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CursorStyle {
    pub shape: CursorShape,
    pub blinking: bool,
}

impl CursorStyle {
    pub fn new() -> Self {
        Self {
            shape: CursorShape::Block,
            blinking: true,
        }
    }

    pub fn from_decscusr_param(param: u16) -> Option<Self> {
        match param {
            0 | 1 => Some(Self {
                shape: CursorShape::Block,
                blinking: true,
            }),
            2 => Some(Self {
                shape: CursorShape::Block,
                blinking: false,
            }),
            3 => Some(Self {
                shape: CursorShape::Underline,
                blinking: true,
            }),
            4 => Some(Self {
                shape: CursorShape::Underline,
                blinking: false,
            }),
            5 => Some(Self {
                shape: CursorShape::Bar,
                blinking: true,
            }),
            6 => Some(Self {
                shape: CursorShape::Bar,
                blinking: false,
            }),
            _ => None,
        }
    }
}

impl Default for CursorStyle {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_and_default() {
        let style_new = CursorStyle::new();
        let style_default = CursorStyle::default();
        assert_eq!(style_new.shape, CursorShape::Block);
        assert!(style_new.blinking);
        assert_eq!(style_new, style_default);
    }

    #[test]
    fn test_from_decscusr_param_valid() {
        assert_eq!(
            CursorStyle::from_decscusr_param(0),
            Some(CursorStyle {
                shape: CursorShape::Block,
                blinking: true,
            })
        );
        assert_eq!(
            CursorStyle::from_decscusr_param(1),
            Some(CursorStyle {
                shape: CursorShape::Block,
                blinking: true,
            })
        );
        assert_eq!(
            CursorStyle::from_decscusr_param(2),
            Some(CursorStyle {
                shape: CursorShape::Block,
                blinking: false,
            })
        );
        assert_eq!(
            CursorStyle::from_decscusr_param(3),
            Some(CursorStyle {
                shape: CursorShape::Underline,
                blinking: true,
            })
        );
        assert_eq!(
            CursorStyle::from_decscusr_param(4),
            Some(CursorStyle {
                shape: CursorShape::Underline,
                blinking: false,
            })
        );
        assert_eq!(
            CursorStyle::from_decscusr_param(5),
            Some(CursorStyle {
                shape: CursorShape::Bar,
                blinking: true,
            })
        );
        assert_eq!(
            CursorStyle::from_decscusr_param(6),
            Some(CursorStyle {
                shape: CursorShape::Bar,
                blinking: false,
            })
        );
    }

    #[test]
    fn test_from_decscusr_param_unrecognized() {
        assert_eq!(CursorStyle::from_decscusr_param(7), None);
        assert_eq!(CursorStyle::from_decscusr_param(99), None);
    }
}
