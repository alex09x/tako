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
/// newline (\n or \r) or any C0 control character other than tab.
pub fn is_unsafe(text: &str) -> bool {
    text.bytes().any(|b| b <= 0x1f && b != b'\t')
}

/// Strips the bracketed-paste terminator from `text` so a hostile paste
/// cannot break out of the brackets, and normalizes \n to \r (terminals
/// expect carriage returns from paste input).
pub fn sanitize(text: &str) -> String {
    text.replace("\x1b[201~", "")
        .replace("\r\n", "\r")
        .replace('\n', "\r")
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
    }

    #[test]
    fn test_paste_end_marker_stripped() {
        assert_eq!(
            encode("hello\x1b[201~world", true),
            b"\x1b[200~helloworld\x1b[201~"
        );
        assert_eq!(encode("hello\x1b[201~world", false), b"helloworld");
        assert_eq!(sanitize("foo\x1b[201~bar\x1b[201~baz"), "foobarbaz");
    }

    #[test]
    fn test_is_unsafe() {
        // Newlines
        assert!(is_unsafe("line1\nline2"));
        assert!(is_unsafe("line1\rline2"));
        assert!(is_unsafe("line1\r\nline2"));

        // Control char 0x03 (ETX / Ctrl+C)
        assert!(is_unsafe("hello\x03world"));

        // Other C0 control chars like 0x00 (NUL)
        assert!(is_unsafe("hello\x00world"));

        // Safe plain text
        assert!(!is_unsafe("hello world"));

        // Safe text containing only tabs
        assert!(!is_unsafe("hello\tworld\t"));
    }
}
