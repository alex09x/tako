#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Charset {
    Ascii,
    DecSpecialGraphics,
    /// UK national set: '#' maps to the pound sign.
    British,
}

pub fn translate(charset: Charset, c: char) -> char {
    match charset {
        Charset::Ascii => c,
        Charset::British => {
            if c == '#' {
                '\u{00A3}'
            } else {
                c
            }
        }
        Charset::DecSpecialGraphics => match c {
            '`' => '\u{25C6}',
            'a' => '\u{2592}',
            'b' => '\u{2409}',
            'c' => '\u{240C}',
            'd' => '\u{240D}',
            'e' => '\u{240A}',
            'f' => '\u{00B0}',
            'g' => '\u{00B1}',
            'h' => '\u{2424}',
            'i' => '\u{240B}',
            'j' => '\u{2518}',
            'k' => '\u{2510}',
            'l' => '\u{250C}',
            'm' => '\u{2514}',
            'n' => '\u{253C}',
            'o' => '\u{23BA}',
            'p' => '\u{23BB}',
            'q' => '\u{2500}',
            'r' => '\u{23BC}',
            's' => '\u{23BD}',
            't' => '\u{251C}',
            'u' => '\u{2524}',
            'v' => '\u{2534}',
            'w' => '\u{252C}',
            'x' => '\u{2502}',
            'y' => '\u{2264}',
            'z' => '\u{2265}',
            '{' => '\u{03C0}',
            '|' => '\u{2260}',
            '}' => '\u{00A3}',
            '~' => '\u{00B7}',
            _ => c,
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_ascii_passthrough() {
        let sample = ['a', 'z', 'A', 'Z', '0', '9', ' ', '`', '~', '\n', '\u{1F600}'];
        for c in sample {
            assert_eq!(translate(Charset::Ascii, c), c);
        }
    }

    #[test]
    fn test_dec_special_graphics_mappings() {
        assert_eq!(translate(Charset::DecSpecialGraphics, 'q'), '\u{2500}');
        assert_eq!(translate(Charset::DecSpecialGraphics, 'x'), '\u{2502}');
        assert_eq!(translate(Charset::DecSpecialGraphics, 'l'), '\u{250C}');
        assert_eq!(translate(Charset::DecSpecialGraphics, 'a'), '\u{2592}');
        assert_eq!(translate(Charset::DecSpecialGraphics, '~'), '\u{00B7}');
        assert_eq!(translate(Charset::DecSpecialGraphics, '`'), '\u{25C6}');
        assert_eq!(translate(Charset::DecSpecialGraphics, 'm'), '\u{2514}');
        assert_eq!(translate(Charset::DecSpecialGraphics, 'j'), '\u{2518}');
        assert_eq!(translate(Charset::DecSpecialGraphics, 'k'), '\u{2510}');
        assert_eq!(translate(Charset::DecSpecialGraphics, 'n'), '\u{253C}');
    }

    #[test]
    fn test_dec_special_graphics_passthrough() {
        let sample = [' ', '0', '1', '9', 'A', 'B', 'Z', '@', '?', '!', '\x1b'];
        for c in sample {
            assert_eq!(translate(Charset::DecSpecialGraphics, c), c);
        }
    }
}
