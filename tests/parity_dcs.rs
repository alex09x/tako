// 1:1 ports of upstream DCS-based query tests: DECRQSS (DCS $ q) and
// XTGETTCAP (DCS + q). Source: upstream `stream_terminal` "DECRQSS responses".

use tako_core::terminal::Terminal;

/// Upstream (stream): "DECRQSS responses" -- SGR request.
#[test]
fn decrqss_sgr() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[1m\x1bP$qm\x1b\\");
    assert_eq!(term.take_output(), b"\x1bP1$r0;1m\x1b\\".to_vec());
}

/// Upstream (stream): "DECRQSS responses" -- an oversized request is
/// ignored entirely, and the next DCS still works.
#[test]
fn decrqss_oversized_request_is_ignored() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[1m");
    term.feed(b"\x1bP$qfoo\x1b\\");
    assert_eq!(term.take_output(), b"".to_vec());
    term.feed(b"\x1bP$qm\x1b\\");
    assert_eq!(term.take_output(), b"\x1bP1$r0;1m\x1b\\".to_vec());
}

/// DECRQSS: scroll region (DECSTBM).
#[test]
fn decrqss_decstbm() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[3;10r");
    term.feed(b"\x1bP$qr\x1b\\");
    assert_eq!(term.take_output(), b"\x1bP1$r3;10r\x1b\\".to_vec());
}

/// DECRQSS: left/right margins (DECSLRM).
#[test]
fn decrqss_decslrm() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[?69h\x1b[5;20s");
    term.feed(b"\x1bP$qs\x1b\\");
    assert_eq!(term.take_output(), b"\x1bP1$r5;20s\x1b\\".to_vec());
}

/// DECRQSS: cursor style (DECSCUSR).
#[test]
fn decrqss_decscusr() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[4 q"); // steady underline
    term.feed(b"\x1bP$q q\x1b\\");
    assert_eq!(term.take_output(), b"\x1bP1$r4 q\x1b\\".to_vec());
}

/// DECRQSS: an unknown setting gets the negative reply.
#[test]
fn decrqss_unknown_setting() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1bP$qZ\x1b\\");
    assert_eq!(term.take_output(), b"\x1bP0$r\x1b\\".to_vec());
}

/// DECRQSS reports truecolor SGR in the colon form.
#[test]
fn decrqss_sgr_truecolor() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b[38;2;1;2;3m\x1bP$qm\x1b\\");
    assert_eq!(
        term.take_output(),
        b"\x1bP1$r0;38:2::1:2:3m\x1b\\".to_vec()
    );
}

/// XTGETTCAP: a known string capability ("TN" = terminal name), hex in,
/// hex out.
#[test]
fn xtgettcap_known_capability() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1bP+q544e\x1b\\"); // "TN"
    // "TN" = 544E. Upstream answers its own terminfo name; we answer what TERM
    // says (see the "TN" arm in src/terminal/mod.rs).
    let expected = b"\x1bP1+r544E=7874657270...".to_vec();
    let got = term.take_output();
    let got_str = String::from_utf8_lossy(&got).into_owned();
    assert!(got_str.starts_with("\x1bP1+r544E="), "{:?}", got_str);
    assert!(got_str.ends_with("\x1b\\"), "{:?}", got_str);
    let _ = expected;
    // Decode the value back and check it.
    let body = got_str
        .trim_start_matches("\x1bP1+r544E=")
        .trim_end_matches("\x1b\\");
    let bytes: Vec<u8> = body
        .as_bytes()
        .chunks(2)
        .map(|p| {
            u8::from_str_radix(std::str::from_utf8(p).unwrap(), 16).unwrap()
        })
        .collect();
    assert_eq!(String::from_utf8(bytes).unwrap(), "xterm-256color");
}

/// XTGETTCAP: an unknown capability gets the negative reply.
#[test]
fn xtgettcap_unknown_capability() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1bP+q7A7A\x1b\\"); // "zz"
    assert_eq!(term.take_output(), b"\x1bP0+r7A7A\x1b\\".to_vec());
}

/// XTGETTCAP: multiple names in one request, semicolon separated.
#[test]
fn xtgettcap_multiple_names() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1bP+q436f;524742\x1b\\"); // "Co", "RGB"
    let got = String::from_utf8_lossy(&term.take_output()).into_owned();
    // Co = 256 -> "323536"
    assert!(got.contains("\x1bP1+r436F=323536\x1b\\"), "{:?}", got);
    assert!(got.contains("\x1bP1+r524742="), "{:?}", got);
}
