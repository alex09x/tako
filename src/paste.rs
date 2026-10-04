/// Wraps `text` for bracketed paste when `bracketed` is true (DEC mode
/// 2004 active), otherwise returns the text bytes unchanged.
pub fn encode(text: &str, bracketed: bool) -> Vec<u8> {
    let sanitized = sanitize(text);
    if bracketed {
        let mut out = Vec::with_capacity(6 + sanitized.len() + 6);
        out.extend_from_slice(b"\x1b[200~");
        out.extend_from_slice(sanitized.as_bytes());
        out.extend_from_slice(b"\x1b[201~");
        out
    } else {
        sanitized.into_bytes()
    }
}

/// True when pasting `text` unbracketed would be unsafe: it contains a
/// newline (\n or \r), any C0 control character other than tab, DEL (0x7f),
/// or any C1 control character (\u{0080}..\u{009f}).
pub fn is_unsafe(text: &str) -> bool {
    text.chars().any(|c| {
        let u = c as u32;
        (u <= 0x1f && c != '\t') || u == 0x7f || (0x80..=0x9f).contains(&u)
    })
}

/// Sanitizes `text` for terminal paste (and drop):
/// 1. Strips bracketed-paste terminators (`\x1b[201~` and `\u{009b}201~`) so a hostile
///    paste cannot prematurely terminate bracketed paste mode.
/// 2. Normalizes newlines: `\r\n` -> `\r`, `\n` -> `\r`, preserving `\r` (terminals
///    expect carriage returns from paste input).
/// 3. Strips or neutralizes all other C0 controls (except tab `\t` and carriage return `\r`),
///    `DEL` (0x7f), and C1 controls (`\u{0080}..=\u{009f}`, e.g. CSI `0x9b`, OSC `0x9d`).
/// 4. Preserves tabs, spaces, multi-line boundaries, and all valid Unicode text.
pub fn sanitize(text: &str) -> String {
    // 1. Remove bracketed-paste end markers before stripping escape/CSI introducers.
    let stripped = text.replace("\x1b[201~", "").replace("\u{009b}201~", "");

    // 2. Normalize newlines to \r and strip disallowed controls.
    let mut out = String::with_capacity(stripped.len());
    let mut chars = stripped.chars().peekable();

    while let Some(c) = chars.next() {
        match c {
            '\r' => {
                if chars.peek() == Some(&'\n') {
                    chars.next();
                }
                out.push('\r');
            }
            '\n' => {
                out.push('\r');
            }
            '\t' => {
                out.push('\t');
            }
            c if (c as u32) <= 0x1f => {
                // Strip C0 controls (e.g. NUL, SOH, Ctrl+C 0x03, BEL 0x07, BS 0x08, ESC 0x1b, etc.)
            }
            '\x7f' => {
                // Strip DEL
            }
            c if (0x80..=0x9f).contains(&(c as u32)) => {
                // Strip C1 controls (\u{0080}..\u{009f}, e.g. CSI \u{009b}, OSC \u{009d})
            }
            other => {
                out.push(other);
            }
        }
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_plain_text() {
        assert_eq!(encode("hello world", true), b"\x1b[200~hello world\x1b[201~");
        assert_eq!(encode("hello world", false), b"hello world");
    }

    #[test]
    fn test_newline_normalization() {
        assert_eq!(sanitize("line1\nline2"), "line1\rline2");
        assert_eq!(sanitize("line1\r\nline2"), "line1\rline2");
        assert_eq!(sanitize("line1\rline2"), "line1\rline2");
        assert_eq!(sanitize("line1\r\nline2\nline3"), "line1\rline2\rline3");
        assert_eq!(sanitize("\r\n\n\r"), "\r\r\r");
    }

    #[test]
    fn test_paste_end_marker_stripped() {
        assert_eq!(
            encode("hello\x1b[201~world", true),
            b"\x1b[200~helloworld\x1b[201~"
        );
        assert_eq!(encode("hello\x1b[201~world", false), b"helloworld");
        assert_eq!(sanitize("foo\x1b[201~bar\x1b[201~baz"), "foobarbaz");

        // C1 variant of bracketed paste terminator: \u{009b}201~
        assert_eq!(
            encode("foo\u{009b}201~bar", true),
            b"\x1b[200~foobar\x1b[201~"
        );
        assert_eq!(encode("foo\u{009b}201~bar", false), b"foobar");
        assert_eq!(sanitize("foo\u{009b}201~bar"), "foobar");
    }

    #[test]
    fn test_c0_controls_stripped_except_tab_and_newline() {
        // NUL (0x00)
        assert_eq!(sanitize("hello\x00world"), "helloworld");
        // SOH (0x01), STX (0x02)
        assert_eq!(sanitize("\x01foo\x02bar"), "foobar");
        // ETX (0x03 / Ctrl+C)
        assert_eq!(sanitize("echo 'stop'\x03"), "echo 'stop'");
        assert_eq!(encode("echo 'stop'\x03", true), b"\x1b[200~echo 'stop'\x1b[201~");
        // EOT (0x04 / Ctrl+D), ENQ (0x05), ACK (0x06), BEL (0x07), BS (0x08)
        assert_eq!(sanitize("a\x04b\x05c\x06d\x07e\x08f"), "abcdef");
        // Tab (0x09) preserved
        assert_eq!(sanitize("\tindent\t"), "\tindent\t");
        assert_eq!(encode("\tcode\t", true), b"\x1b[200~\tcode\t\x1b[201~");
        // VT (0x0b), FF (0x0c)
        assert_eq!(sanitize("a\x0bb\x0cc"), "abc");
        // CR (0x0d) and LF (0x0a) normalized to \r
        assert_eq!(sanitize("a\nb\rc"), "a\rb\rc");
        // SO (0x0e), SI (0x0f), DLE..US (0x10..0x1f)
        assert_eq!(sanitize("a\x0eb\x0fc\x10d\x1fe"), "abcde");
        // ESC (0x1b)
        assert_eq!(sanitize("hello\x1bworld"), "helloworld");
        // ANSI CSI sequence: ESC [ 31 m
        assert_eq!(sanitize("hello\x1b[31mworld\x1b[0m"), "hello[31mworld[0m");
        // OSC sequence: ESC ] 52 ; c ; payload BEL
        assert_eq!(sanitize("\x1b]52;c;data\x07"), "]52;c;data");
    }

    #[test]
    fn test_del_stripped() {
        assert_eq!(sanitize("hello\x7fworld"), "helloworld");
        assert_eq!(encode("hello\x7fworld", true), b"\x1b[200~helloworld\x1b[201~");
    }

    #[test]
    fn test_c1_controls_stripped() {
        // C1 CSI: \u{009b}
        assert_eq!(sanitize("hello\u{009b}2Jworld"), "hello2Jworld");
        assert_eq!(encode("hello\u{009b}2Jworld", true), b"\x1b[200~hello2Jworld\x1b[201~");
        // C1 OSC: \u{009d}
        assert_eq!(sanitize("cmd\u{009d}52;c;test\u{009c}"), "cmd52;c;test");
        // C1 DCS: \u{0090}, C1 APC: \u{009f}, C1 SOS: \u{0098}
        assert_eq!(sanitize("a\u{0090}b\u{0098}c\u{009f}d"), "abcd");
    }

    #[test]
    fn test_unicode_and_code_blocks_preserved() {
        // Emojis, accents, Cyrillic, CJK
        let text = "Привет, мир! 🦀 🐙 你好 世界 café naïve";
        assert_eq!(sanitize(text), text);
        assert_eq!(encode(text, false), text.as_bytes());

        // Multi-line code snippet with tabs and newlines
        let code = "def test():\n\tif True:\n\t\tprint(\"ok 🦀\")\n";
        let expected = "def test():\r\tif True:\r\t\tprint(\"ok 🦀\")\r";
        assert_eq!(sanitize(code), expected);
        assert_eq!(
            encode(code, true),
            format!("\x1b[200~{}\x1b[201~", expected).into_bytes()
        );
    }

    #[test]
    fn test_is_unsafe() {
        // Newlines
        assert!(is_unsafe("line1\nline2"));
        assert!(is_unsafe("line1\rline2"));
        assert!(is_unsafe("line1\r\nline2"));

        // C0 control chars like 0x03 (ETX / Ctrl+C), 0x00 (NUL), 0x1b (ESC)
        assert!(is_unsafe("hello\x03world"));
        assert!(is_unsafe("hello\x00world"));
        assert!(is_unsafe("hello\x1bworld"));

        // DEL (0x7f)
        assert!(is_unsafe("hello\x7fworld"));

        // C1 controls (\u{0080}..\u{009f})
        assert!(is_unsafe("hello\u{009b}world"));
        assert!(is_unsafe("hello\u{009d}world"));
        assert!(is_unsafe("hello\u{0080}world"));

        // Safe plain text
        assert!(!is_unsafe("hello world"));
        assert!(!is_unsafe(""));

        // Safe text containing only tabs
        assert!(!is_unsafe("hello\tworld\t"));

        // Safe Unicode text
        assert!(!is_unsafe("Привет мир 🦀 🐙 café 你好"));
    }
}
