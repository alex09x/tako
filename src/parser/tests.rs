use crate::parser::*;

#[derive(Debug, PartialEq, Clone)]
pub enum Action {
    Print(char),
    PrintSlice(Vec<u8>),
    Execute(u8),
    Hook(Vec<u16>, u32, Vec<u8>, bool, char),
    Put(u8),
    Unhook,
    OscDispatch(Vec<Vec<u8>>, bool),
    CsiDispatch(Vec<u16>, u32, Vec<u8>, bool, char),
    EscDispatch(Vec<u8>, bool, u8),
    ApcDispatch(Vec<u8>),
}

pub struct MockPerformer {
    pub actions: Vec<Action>,
}

impl Perform for MockPerformer {
    fn print(&mut self, c: char) { self.actions.push(Action::Print(c)); }
    fn print_slice(&mut self, bytes: &[u8]) { self.actions.push(Action::PrintSlice(bytes.to_vec())); }
    fn execute(&mut self, byte: u8) { self.actions.push(Action::Execute(byte)); }
    fn hook(&mut self, params: &[u16], params_sep: u32, intermediates: &[u8], ignore: bool, action: char) {
        self.actions.push(Action::Hook(params.to_vec(), params_sep, intermediates.to_vec(), ignore, action));
    }
    fn put(&mut self, byte: u8) { self.actions.push(Action::Put(byte)); }
    fn unhook(&mut self) { self.actions.push(Action::Unhook); }
    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        self.actions.push(Action::OscDispatch(params.iter().map(|s| s.to_vec()).collect(), bell_terminated));
    }
    fn csi_dispatch(&mut self, params: &[u16], params_sep: u32, intermediates: &[u8], ignore: bool, action: char) {
        self.actions.push(Action::CsiDispatch(params.to_vec(), params_sep, intermediates.to_vec(), ignore, action));
    }
    fn esc_dispatch(&mut self, intermediates: &[u8], ignore: bool, byte: u8) {
        self.actions.push(Action::EscDispatch(intermediates.to_vec(), ignore, byte));
    }
    fn apc_dispatch(&mut self, data: &[u8]) {
        self.actions.push(Action::ApcDispatch(data.to_vec()));
    }
}

fn parse_str(s: &str) -> MockPerformer {
    let mut parser = Parser::new();
    let mut performer = MockPerformer { actions: Vec::new() };
    for b in s.bytes() {
        parser.advance(&mut performer, b);
    }
    performer
}

fn advance_bytes_scalar<P: Perform>(parser: &mut Parser, performer: &mut P, bytes: &[u8]) {
    let mut offset = 0;
    while offset < bytes.len() {
        if parser.state == State::Ground && parser.utf8_need == 0 {
            let start = offset;
            while offset < bytes.len() && matches!(bytes[offset], 0x20..=0x7F) {
                offset += 1;
            }
            if offset - start > 1 {
                performer.print_slice(&bytes[start..offset]);
                continue;
            }
            offset = start;
        }

        parser.advance(performer, bytes[offset]);
        offset += 1;
    }
}

fn assert_parser_fields_eq(actual: &Parser, expected: &Parser) {
    assert_eq!(actual.state, expected.state);
    assert_eq!(actual.intermediates, expected.intermediates);
    assert_eq!(actual.params, expected.params);
    assert_eq!(actual.params_sep, expected.params_sep);
    assert_eq!(actual.ignore, expected.ignore);
    assert_eq!(actual.osc_raw, expected.osc_raw);
    assert_eq!(actual.apc_raw, expected.apc_raw);
    assert_eq!(actual.utf8_need, expected.utf8_need);
    assert_eq!(actual.utf8_cp, expected.utf8_cp);
}

fn deterministic_byte(seed: &mut u64) -> u8 {
    let mut x = *seed;
    x ^= x << 7;
    x ^= x >> 9;
    x ^= x << 8;
    *seed = x;
    (x & 0xff) as u8
}

fn assert_advance_bytes_matches_scalar(bytes: &[u8]) {
    let mut fast = Parser::new();
    let mut fast_performer = MockPerformer { actions: Vec::new() };
    fast.advance_bytes(&mut fast_performer, bytes);

    let mut scalar = Parser::new();
    let mut scalar_performer = MockPerformer { actions: Vec::new() };
    advance_bytes_scalar(&mut scalar, &mut scalar_performer, bytes);

    assert_eq!(fast_performer.actions, scalar_performer.actions);
    assert_parser_fields_eq(&fast, &scalar);
}

#[test]
fn advance_bytes_batches_only_ground_state_ascii() {
    let mut parser = Parser::new();
    let mut performer = MockPerformer { actions: Vec::new() };
    parser.advance_bytes(&mut performer, b"hello\n\x1b[31mred");

    assert_eq!(
        performer.actions,
        vec![
            Action::PrintSlice(b"hello".to_vec()),
            Action::Execute(b'\n'),
            Action::CsiDispatch(vec![31], 0, vec![], false, 'm'),
            Action::PrintSlice(b"red".to_vec()),
        ]
    );
}

#[test]
fn advance_bytes_matches_scalar_reference_all_bytes() {
    let mut bytes: Vec<u8> = (0u8..=u8::MAX).collect();
    bytes.extend_from_slice(b"abc");
    assert_advance_bytes_matches_scalar(&bytes);
}

#[test]
fn advance_bytes_matches_scalar_reference_short_tail_and_random_sequences() {
    let seed = 0xD1EC_0DE0_BADA_55A5u64;
    for len in 0..64usize {
        let mut bytes = Vec::with_capacity(len);
        let mut mix = seed
            .wrapping_add(len as u64)
            .wrapping_mul(0x9E37_79B9_7F4A_7C15);
        for _ in 0..len {
            bytes.push(deterministic_byte(&mut mix));
        }
        assert_advance_bytes_matches_scalar(&bytes);

        let mut border = Vec::with_capacity(len + 32);
        border.extend(std::iter::repeat_n(0x20u8, 15));
        border.extend(std::iter::repeat_n(0x20u8, len % 2));
        border.push(0x1B);
        border.extend(std::iter::repeat_n(b'X', 17));
        border.extend_from_slice(&bytes);
        assert_advance_bytes_matches_scalar(&border);
    }

    assert_advance_bytes_matches_scalar(b"\x1B[31mHello\x07");
    assert_advance_bytes_matches_scalar(b"\x1B]0;Title\x1B\\");
}

#[test]
fn test_esc_b() {
    let mut parser = Parser::new();
    let mut performer = MockPerformer { actions: Vec::new() };
    parser.advance(&mut performer, 0x1B);
    parser.advance(&mut performer, b'(');
    parser.advance(&mut performer, b'B');
    
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions.len(), 1);
    if let Action::EscDispatch(intermediates, ignore, byte) = &performer.actions[0] {
        assert_eq!(byte, &b'B');
        assert_eq!(intermediates, &vec![b'(']);
        assert!(!(*ignore));
    } else {
        panic!("Wrong action");
    }
}

#[test]
fn test_csi_h() {
    let mut parser = Parser::new();
    let mut p = MockPerformer { actions: Vec::new() };
    parser.advance(&mut p, 0x1B);
    parser.advance(&mut p, b'[');
    parser.advance(&mut p, b'H');
    
    assert_eq!(parser.state, State::Ground);
    assert_eq!(p.actions.len(), 1);
    if let Action::CsiDispatch(params, _sep, _intermediates, _ignore, action) = &p.actions[0] {
        assert_eq!(*action, 'H');
        assert_eq!(params.len(), 0);
    } else {
        panic!("Wrong action");
    }
}

#[test]
fn test_csi_1_4_h() {
    let mut parser = Parser::new();
    let mut p = MockPerformer { actions: Vec::new() };
    parser.advance(&mut p, 0x1B);
    parser.advance(&mut p, b'[');
    parser.advance(&mut p, b'1');
    parser.advance(&mut p, b';');
    parser.advance(&mut p, b'4');
    parser.advance(&mut p, b'H');
    
    assert_eq!(parser.state, State::Ground);
    if let Action::CsiDispatch(params, _sep, _intermediates, _ignore, action) = &p.actions[0] {
        assert_eq!(*action, 'H');
        assert_eq!(params.len(), 2);
        assert_eq!(params[0], 1);
        assert_eq!(params[1], 4);
    } else {
        panic!("Wrong action");
    }
}

#[test]
fn test_csi_sgr_colon() {
    let mut parser = Parser::new();
    let mut p = MockPerformer { actions: Vec::new() };
    for b in b"\x1B[38:2m" {
        parser.advance(&mut p, *b);
    }
    
    assert_eq!(parser.state, State::Ground);
    if let Action::CsiDispatch(params, sep, _intermediates, _ignore, action) = &p.actions[0] {
        assert_eq!(*action, 'm');
        assert_eq!(params.len(), 2);
        assert_eq!(params[0], 38);
        assert_eq!(params[1], 2);
        assert_eq!(sep & (1 << 0), 1); // first sep is colon
    } else {
        panic!("Wrong action");
    }
}

#[test]
fn test_osc_title() {
    let mut parser = Parser::new();
    let mut p = MockPerformer { actions: Vec::new() };
    for b in b"\x1B]0;Hello\x07" {
        parser.advance(&mut p, *b);
    }
    
    assert_eq!(parser.state, State::Ground);
    if let Action::OscDispatch(params, bell) = &p.actions[0] {
        assert!(*bell);
        assert_eq!(params.len(), 2);
        assert_eq!(params[0], b"0");
        assert_eq!(params[1], b"Hello");
    } else {
        panic!("Wrong action");
    }
}

#[test]
fn test_osc_title_st() {
    let mut parser = Parser::new();
    let mut p = MockPerformer { actions: Vec::new() };
    for b in b"\x1B]0;Hello\x1B\\" {
        parser.advance(&mut p, *b);
    }
    
    assert_eq!(parser.state, State::Ground);
    if let Action::OscDispatch(params, bell) = &p.actions[0] {
        assert!(!(*bell));
        assert_eq!(params.len(), 2);
        assert_eq!(params[0], b"0");
        assert_eq!(params[1], b"Hello");
    } else {
        panic!("Wrong action");
    }
}

#[test]
fn test_osc_utf8_claude_symbol_whole_and_split_feed() {
    // Claude symbol U+2733 is UTF-8 encoded as E2 9C B3.
    let claude_symbol_bytes = "\u{2733}".as_bytes(); // [0xE2, 0x9C, 0xB3]
    assert_eq!(claude_symbol_bytes, &[0xE2, 0x9C, 0xB3]);

    // 1. Whole feed terminated with BEL (0x07)
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        for &b in b"\x1B]0;Claude \xE2\x9C\xB3 symbol\x07" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(p.actions.len(), 1);
        if let Action::OscDispatch(params, bell) = &p.actions[0] {
            assert!(*bell);
            assert_eq!(params.len(), 2);
            assert_eq!(params[0], b"0");
            assert_eq!(params[1], "Claude \u{2733} symbol".as_bytes());
        } else {
            panic!("Expected OscDispatch");
        }
    }

    // 2. Whole feed terminated with ESC \ (0x1B 0x5C)
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        for &b in b"\x1B]0;Claude \xE2\x9C\xB3 symbol\x1B\\" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![
                Action::OscDispatch(vec![b"0".to_vec(), "Claude \u{2733} symbol".as_bytes().to_vec()], false),
                Action::EscDispatch(vec![], false, b'\\'),
            ]
        );
    }

    // 3. Whole feed terminated with genuine bare C1 ST (0x9C)
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        for &b in b"\x1B]0;Claude \xE2\x9C\xB3 symbol\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::OscDispatch(
                vec![b"0".to_vec(), "Claude \u{2733} symbol".as_bytes().to_vec()],
                false
            )]
        );
    }

    // 4. Split feed split right on the continuation byte 0x9C
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        let chunk1 = b"\x1B]0;Claude \xE2";
        let chunk2 = b"\x9C\xB3 symbol\x07";
        for &b in chunk1 {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::OscString);
        for &b in chunk2 {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::OscDispatch(
                vec![b"0".to_vec(), "Claude \u{2733} symbol".as_bytes().to_vec()],
                true
            )]
        );
    }

    // 5. Byte-by-byte feed terminated by bare C1 ST
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        for &b in b"\x1B]0;Claude \xE2\x9C\xB3 symbol\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::OscDispatch(
                vec![b"0".to_vec(), "Claude \u{2733} symbol".as_bytes().to_vec()],
                false
            )]
        );
    }
}

#[test]
fn test_apc_utf8_claude_symbol_whole_and_split_feed() {
    // 1. Whole feed terminated with ESC \
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        for &b in b"\x1B_GClaude \xE2\x9C\xB3 symbol\x1B\\" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![
                Action::ApcDispatch("GClaude \u{2733} symbol".as_bytes().to_vec()),
                Action::EscDispatch(vec![], false, b'\\'),
            ]
        );
    }

    // 2. Whole feed terminated with bare C1 ST (0x9C)
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        for &b in b"\x1B_GClaude \xE2\x9C\xB3 symbol\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::ApcDispatch("GClaude \u{2733} symbol".as_bytes().to_vec())]
        );
    }

    // 3. Split feed split right on the continuation byte 0x9C
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        let chunk1 = b"\x1B_GClaude \xE2";
        let chunk2 = b"\x9C\xB3 symbol\x9C";
        for &b in chunk1 {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::SosPmApcString);
        for &b in chunk2 {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::ApcDispatch("GClaude \u{2733} symbol".as_bytes().to_vec())]
        );
    }
}

#[test]
fn test_osc_and_apc_genuine_bare_c1_st() {
    // OSC string terminated by bare C1 ST 0x9C when no UTF-8 continuation is pending
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        for &b in b"\x1B]0;My Title\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::OscDispatch(
                vec![b"0".to_vec(), b"My Title".to_vec()],
                false
            )]
        );
    }

    // APC string terminated by bare C1 ST 0x9C when no UTF-8 continuation is pending
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        for &b in b"\x1B_Ga=T,f=100;payload_data\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::ApcDispatch(b"Ga=T,f=100;payload_data".to_vec())]
        );
    }
}

#[test]
fn test_osc_and_apc_encoded_u009c() {
    // U+009C encoded in UTF-8 is C2 9C.
    let encoded_c1_st = "\u{009C}".as_bytes();
    assert_eq!(encoded_c1_st, &[0xC2, 0x9C]);

    // OSC with encoded U+009C in payload, terminated with BEL
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        for &b in b"\x1B]0;pre\xC2\x9Cpost\x07" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::OscDispatch(
                vec![b"0".to_vec(), b"pre\xC2\x9Cpost".to_vec()],
                true
            )]
        );
    }

    // OSC with encoded U+009C in payload, terminated with ESC \
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        for &b in b"\x1B]0;pre\xC2\x9Cpost\x1B\\" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![
                Action::OscDispatch(vec![b"0".to_vec(), b"pre\xC2\x9Cpost".to_vec()], false),
                Action::EscDispatch(vec![], false, b'\\'),
            ]
        );
    }

    // OSC with encoded U+009C in payload, terminated with bare C1 ST 0x9C
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        for &b in b"\x1B]0;pre\xC2\x9Cpost\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::OscDispatch(
                vec![b"0".to_vec(), b"pre\xC2\x9Cpost".to_vec()],
                false
            )]
        );
    }

    // APC with encoded U+009C in payload, terminated with bare C1 ST 0x9C
    {
        let mut parser = Parser::new();
        let mut p = MockPerformer { actions: Vec::new() };
        for &b in b"\x1B_Gpre\xC2\x9Cpost\x9C" {
            parser.advance(&mut p, b);
        }
        assert_eq!(parser.state, State::Ground);
        assert_eq!(
            p.actions,
            vec![Action::ApcDispatch(b"Gpre\xC2\x9Cpost".to_vec())]
        );
    }
}

#[test]
fn test_utf8_multibyte_sequences_decode_to_single_print_actions() {
    let performer = parse_str("h\u{00e9}\u{4e2d}\u{1f600}i");
    let printed: Vec<char> = performer
        .actions
        .iter()
        .filter_map(|a| match a {
            Action::Print(c) => Some(*c),
            _ => None,
        })
        .collect();
    assert_eq!(printed, vec!['h', '\u{00e9}', '\u{4e2d}', '\u{1f600}', 'i']);
}

#[test]
fn test_stray_utf8_continuation_byte_prints_replacement_char_without_panicking() {
    let mut parser = Parser::new();
    let mut performer = MockPerformer { actions: Vec::new() };
    // A continuation byte (0x80..=0xBF) with no preceding lead byte.
    parser.advance(&mut performer, 0x80);
    parser.advance(&mut performer, b'x');
    assert_eq!(
        performer.actions,
        vec![Action::Print('\u{FFFD}'), Action::Print('x')]
    );
}

#[test]
fn test_malformed_ground_state_utf8_replacement_chars() {
    // 1. Bare continuation bytes in ground state yield replacement character U+FFFD
    {
        let mut parser = Parser::new();
        let mut performer = MockPerformer { actions: Vec::new() };
        parser.advance(&mut performer, 0x9C); // Standalone 0x9C in ground state
        parser.advance(&mut performer, 0xBF);
        assert_eq!(
            performer.actions,
            vec![Action::Print('\u{FFFD}'), Action::Print('\u{FFFD}')]
        );
    }

    // 2. Invalid UTF-8 lead bytes in ground state yield replacement character U+FFFD
    {
        let mut parser = Parser::new();
        let mut performer = MockPerformer { actions: Vec::new() };
        for &b in &[0xC0, 0xC1, 0xF5, 0xFF] {
            parser.advance(&mut performer, b);
        }
        assert_eq!(
            performer.actions,
            vec![
                Action::Print('\u{FFFD}'),
                Action::Print('\u{FFFD}'),
                Action::Print('\u{FFFD}'),
                Action::Print('\u{FFFD}'),
            ]
        );
    }
}
