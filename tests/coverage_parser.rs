use tako_core::parser::{Parser, ParserSnapshot, Perform, State};
use tako_core::terminal::Terminal;

/// Action recorded by the test performer.
#[derive(Debug, PartialEq, Clone)]
enum Action {
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

/// A full recording performer that captures all callbacks including batch print and APC.
#[derive(Default)]
struct TestPerformer {
    actions: Vec<Action>,
}

impl Perform for TestPerformer {
    fn print(&mut self, c: char) {
        self.actions.push(Action::Print(c));
    }
    fn print_slice(&mut self, bytes: &[u8]) {
        self.actions.push(Action::PrintSlice(bytes.to_vec()));
    }
    fn execute(&mut self, byte: u8) {
        self.actions.push(Action::Execute(byte));
    }
    fn hook(
        &mut self,
        params: &[u16],
        params_sep: u32,
        intermediates: &[u8],
        ignore: bool,
        action: char,
    ) {
        self.actions.push(Action::Hook(
            params.to_vec(),
            params_sep,
            intermediates.to_vec(),
            ignore,
            action,
        ));
    }
    fn put(&mut self, byte: u8) {
        self.actions.push(Action::Put(byte));
    }
    fn unhook(&mut self) {
        self.actions.push(Action::Unhook);
    }
    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        self.actions.push(Action::OscDispatch(
            params.iter().map(|s| s.to_vec()).collect(),
            bell_terminated,
        ));
    }
    fn csi_dispatch(
        &mut self,
        params: &[u16],
        params_sep: u32,
        intermediates: &[u8],
        ignore: bool,
        action: char,
    ) {
        self.actions.push(Action::CsiDispatch(
            params.to_vec(),
            params_sep,
            intermediates.to_vec(),
            ignore,
            action,
        ));
    }
    fn esc_dispatch(&mut self, intermediates: &[u8], ignore: bool, byte: u8) {
        self.actions
            .push(Action::EscDispatch(intermediates.to_vec(), ignore, byte));
    }
    fn apc_dispatch(&mut self, data: &[u8]) {
        self.actions.push(Action::ApcDispatch(data.to_vec()));
    }
}

/// A performer that uses default trait implementations for print_slice and apc_dispatch.
#[derive(Default)]
struct DefaultTraitPerformer {
    printed_chars: Vec<char>,
    _executed: Vec<u8>,
}

impl Perform for DefaultTraitPerformer {
    fn print(&mut self, c: char) {
        self.printed_chars.push(c);
    }
    fn execute(&mut self, byte: u8) {
        self._executed.push(byte);
    }
    fn hook(
        &mut self,
        _params: &[u16],
        _params_sep: u32,
        _intermediates: &[u8],
        _ignore: bool,
        _action: char,
    ) {
    }
    fn put(&mut self, _byte: u8) {}
    fn unhook(&mut self) {}
    fn osc_dispatch(&mut self, _params: &[&[u8]], _bell_terminated: bool) {}
    fn csi_dispatch(
        &mut self,
        _params: &[u16],
        _params_sep: u32,
        _intermediates: &[u8],
        _ignore: bool,
        _action: char,
    ) {
    }
    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, _byte: u8) {}
}

/// The default `print_slice` splits a slice into byte-by-byte `print` calls.
#[test]
fn default_perform_print_slice() {
    let mut parser = Parser::new();
    let mut performer = DefaultTraitPerformer::default();
    parser.advance_bytes(&mut performer, b"Rust");
    assert_eq!(performer.printed_chars, vec!['R', 'u', 's', 't']);
}

/// APC sequences dispatch through the trait default without panic.
#[test]
fn default_perform_apc_dispatch() {
    let mut parser = Parser::new();
    let mut performer = DefaultTraitPerformer::default();
    parser.advance_bytes(&mut performer, b"\x1b_test-payload\x1b\\");
    assert_eq!(parser.state, State::Ground);
}

/// Pins parser retained heap capacity tracking for in-flight OSC allocations.
#[test]
fn parser_retained_capacity_empty_and_buffers() {
    let mut parser = Parser::default();
    assert_eq!(parser.retained_capacity_bytes(), 0);

    let mut performer = TestPerformer::default();
    parser.advance(&mut performer, 0x1B);
    parser.advance(&mut performer, b']');
    for _ in 0..64 {
        parser.advance(&mut performer, b'A');
    }
    let osc_cap = parser.retained_capacity_bytes();
    assert!(
        osc_cap >= 64,
        "expected at least 64 bytes retained, got {osc_cap}"
    );
}

/// Pins parser retained capacity accounting when intermediates spill beyond inline storage.
#[test]
fn parser_retained_capacity_spilled_intermediates() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();
    // Feed CSI with 4 intermediates: SmallVec inline capacity is 2, so 4 forces heap spill.
    parser.advance(&mut performer, 0x1B);
    parser.advance(&mut performer, b'[');
    parser.advance(&mut performer, b' ');
    parser.advance(&mut performer, b'!');
    parser.advance(&mut performer, b'"');
    parser.advance(&mut performer, b'#');
    assert_eq!(parser.state, State::CsiIntermediate);
    let cap = parser.retained_capacity_bytes();
    assert!(
        cap >= 4,
        "intermediates spilled to heap must be counted in retained capacity: {cap}"
    );
    let view = parser.view();
    assert_eq!(view.intermediates, b" !\"#");
}

/// Pins parser retained capacity accounting when params spill beyond inline storage.
#[test]
fn parser_retained_capacity_spilled_params() {
    let mut parser = Parser::new();
    let mut params = smallvec::SmallVec::<[u16; 16]>::new();
    for i in 0..24 {
        params.push(i);
    }
    assert!(params.spilled(), "24 params must spill past 16 inline slots");
    let snap = ParserSnapshot {
        state: State::CsiParam,
        intermediates: smallvec::SmallVec::new(),
        params,
        params_sep: 0,
        ignore: false,
        osc_raw: Vec::new(),
        apc_raw: Vec::new(),
        utf8_need: 0,
        utf8_cp: 0,
    };
    parser.restore(snap);
    let cap = parser.retained_capacity_bytes();
    assert!(
        cap >= 48,
        "spilled params (24 * 2 = 48 bytes min) must be counted: {cap}"
    );
}

/// parser checkpoint snapshot copies owned state and restore recovers continuation exactly.
#[test]
fn parser_snapshot_and_restore_fidelity() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();
    parser.advance_bytes(&mut performer, b"\x1b[12:34$");
    assert_eq!(parser.state, State::CsiIntermediate);

    let snap = parser.snapshot();
    assert_eq!(snap.state, State::CsiIntermediate);
    assert_eq!(snap.params.as_slice(), &[12, 34]);
    assert_eq!(snap.params_sep, 1);
    assert_eq!(snap.intermediates.as_slice(), b"$");
    assert!(!snap.ignore);

    let mut restored = Parser::default();
    restored.restore(snap);
    assert_eq!(restored.view().state, State::CsiIntermediate);
    assert_eq!(restored.view().params, &[12, 34]);
    assert_eq!(restored.view().params_sep, 1);
    assert_eq!(restored.view().intermediates, b"$");

    let mut finish_performer = TestPerformer::default();
    restored.advance(&mut finish_performer, b'p');
    assert_eq!(restored.state, State::Ground);
    assert_eq!(
        finish_performer.actions,
        vec![Action::CsiDispatch(vec![12, 34], 1, vec![b'$'], false, 'p')]
    );
}

/// CSI colon and semicolon with empty params initialize first param to 0.
#[test]
fn csi_entry_colon_and_semicolon_empty_params() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();
    parser.advance_bytes(&mut performer, b"\x1b[:5m");
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![0, 5], 1, vec![], false, 'm')]
    );

    performer.actions.clear();
    parser.advance_bytes(&mut performer, b"\x1b[;7m");
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![0, 7], 0, vec![], false, 'm')]
    );
}

/// parameters beyond 16 are ignored without overflowing SmallVec.
#[test]
fn csi_param_max_capacity_bound() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();
    parser.advance_bytes(
        &mut performer,
        b"\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20m",
    );
    assert_eq!(performer.actions.len(), 1);
    if let Action::CsiDispatch(params, _sep, _inter, _ignore, action) = &performer.actions[0] {
        assert_eq!(*action, 'm');
        assert_eq!(params.len(), 16);
        // Parameters up to slot 15 are exact; subsequent digits accumulate into slot 16 saturating at u16::MAX
        assert_eq!(
            params,
            &[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 65535]
        );
    } else {
        panic!("expected CsiDispatch");
    }
}

/// EscapeIntermediate handles CAN/SUB, ESC restart, and invalid bytes.
#[test]
fn escape_intermediate_control_and_transitions() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // CAN (0x18) executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b( \x18");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x18)]);

    performer.actions.clear();
    // SUB (0x1A) executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b( \x1a");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x1A)]);

    performer.actions.clear();
    // ESC (0x1B) cancels previous sequence and starts fresh Escape
    parser.advance_bytes(&mut performer, b"\x1b( \x1b[H");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![], 0, vec![], false, 'H')]
    );

    performer.actions.clear();
    // Invalid byte (0x80) resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b( \x80");
    assert_eq!(parser.state, State::Ground);
}

/// CsiEntry handles CAN/SUB, ESC restart, and non-ASCII fallback.
#[test]
fn csi_entry_control_and_transitions() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // CAN (0x18) in CsiEntry executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b[\x18");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x18)]);

    performer.actions.clear();
    // SUB (0x1A) in CsiEntry executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b[\x1a");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x1A)]);

    performer.actions.clear();
    // ESC (0x1B) in CsiEntry restarts Escape state
    parser.advance_bytes(&mut performer, b"\x1b[\x1b[H");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![], 0, vec![], false, 'H')]
    );

    performer.actions.clear();
    // Non-ASCII byte (0x80) in CsiEntry falls through to Ground
    parser.advance_bytes(&mut performer, b"\x1b[\x80");
    assert_eq!(parser.state, State::Ground);
}

/// CsiParam handles CAN/SUB, ESC restart, private marker ignore, and non-ASCII fallback.
#[test]
fn csi_param_control_and_transitions() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // CAN (0x18) in CsiParam executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b[12\x18");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x18)]);

    performer.actions.clear();
    // SUB (0x1A) in CsiParam executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b[12\x1a");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x1A)]);

    performer.actions.clear();
    // ESC (0x1B) in CsiParam restarts Escape
    parser.advance_bytes(&mut performer, b"\x1b[12\x1b[H");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![], 0, vec![], false, 'H')]
    );

    performer.actions.clear();
    // Private marker in CsiParam sets ignore flag
    parser.advance_bytes(&mut performer, b"\x1b[12?m");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![12], 0, vec![], true, 'm')]
    );

    performer.actions.clear();
    // Non-ASCII byte (0x80) in CsiParam transitions to Ground
    parser.advance_bytes(&mut performer, b"\x1b[12\x80");
    assert_eq!(parser.state, State::Ground);
}

/// CsiIntermediate handles CAN/SUB, ESC restart, trailing digits, and non-ASCII fallback.
#[test]
fn csi_intermediate_control_and_transitions() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // CAN in CsiIntermediate executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b[ $\x18");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x18)]);

    performer.actions.clear();
    // SUB in CsiIntermediate executes and resets to Ground
    parser.advance_bytes(&mut performer, b"\x1b[ $\x1a");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions, vec![Action::Execute(0x1A)]);

    performer.actions.clear();
    // ESC in CsiIntermediate restarts Escape
    parser.advance_bytes(&mut performer, b"\x1b[ $\x1b[H");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![], 0, vec![], false, 'H')]
    );

    performer.actions.clear();
    // Digit after intermediate sets ignore flag
    parser.advance_bytes(&mut performer, b"\x1b[ $1m");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(
            vec![],
            0,
            vec![b' ', b'$'],
            true,
            'm'
        )]
    );

    performer.actions.clear();
    // Non-ASCII byte in CsiIntermediate transitions to Ground
    parser.advance_bytes(&mut performer, b"\x1b[ $\x80");
    assert_eq!(parser.state, State::Ground);
}

/// DcsEntry handles direct colon/semicolon params and non-ASCII fallback.
#[test]
fn dcs_entry_colon_semicolon_and_fallback() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // Semicolon immediately after DCS entry creates param 0; terminated with 7-bit ST (ESC \)
    parser.advance_bytes(&mut performer, b"\x1bP;2p\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![0, 2], 0, vec![], false, 'p'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // Colon immediately after DCS entry creates colon-separated param 0
    parser.advance_bytes(&mut performer, b"\x1bP:2p\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![0, 2], 1, vec![], false, 'p'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // Non-ASCII byte in DcsEntry transitions to Ground
    parser.advance_bytes(&mut performer, b"\x1bP\x80");
    assert_eq!(parser.state, State::Ground);
}

/// DcsParam handles control ignore, CAN/SUB cancel, intermediates, colons, markers, and actions.
#[test]
fn dcs_param_comprehensive() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // In DcsParam: control byte (0x05) ignored without leaving state
    parser.advance_bytes(&mut performer, b"\x1bP1\x05");
    assert_eq!(parser.state, State::DcsParam);

    // CAN cancels to Escape
    parser.advance(&mut performer, 0x18);
    assert_eq!(parser.state, State::Escape);
    parser.advance(&mut performer, b'c');
    assert_eq!(parser.state, State::Ground);

    performer.actions.clear();
    // SUB cancels to Escape
    parser.advance_bytes(&mut performer, b"\x1bP1\x1a");
    assert_eq!(parser.state, State::Escape);
    parser.advance(&mut performer, b'c');
    assert_eq!(parser.state, State::Ground);

    performer.actions.clear();
    // Intermediate transition in DcsParam
    parser.advance_bytes(&mut performer, b"\x1bP1 $q\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![1], 0, vec![b' ', b'$'], false, 'q'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // Colon and semicolon and digit parsing in DcsParam
    parser.advance_bytes(&mut performer, b"\x1bP12;34:56p\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![12, 34, 56], 2, vec![], false, 'p'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // Private marker in DcsParam sets ignore flag
    parser.advance_bytes(&mut performer, b"\x1bP1?p\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![1], 0, vec![], true, 'p'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // Non-ASCII byte in DcsParam transitions to Ground
    parser.advance_bytes(&mut performer, b"\x1bP1\x80");
    assert_eq!(parser.state, State::Ground);
}

/// DcsIntermediate handles CAN/SUB, ESC restart, digits setting ignore, and non-ASCII fallback.
#[test]
fn dcs_intermediate_control_and_transitions() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // CAN in DcsIntermediate transitions to Escape
    parser.advance_bytes(&mut performer, b"\x1bP $\x18");
    assert_eq!(parser.state, State::Escape);

    // SUB in DcsIntermediate transitions to Escape
    parser.advance_bytes(&mut performer, b"c\x1bP $\x1a");
    assert_eq!(parser.state, State::Escape);

    // ESC in DcsIntermediate transitions to Escape
    parser.advance_bytes(&mut performer, b"c\x1bP $\x1b[H");
    assert_eq!(parser.state, State::Ground);

    performer.actions.clear();
    // Digit in DcsIntermediate sets ignore flag
    parser.advance_bytes(&mut performer, b"\x1bP $1p\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![], 0, vec![b' ', b'$'], true, 'p'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // Non-ASCII byte in DcsIntermediate transitions to Ground
    parser.advance_bytes(&mut performer, b"\x1bP $\x80");
    assert_eq!(parser.state, State::Ground);
}

/// DcsPassthrough routes control bytes to put and unhooks on CAN/SUB or non-ASCII.
#[test]
fn dcs_passthrough_control_put_and_cancel() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // Control byte < 0x20 during passthrough is routed to put()
    parser.advance_bytes(&mut performer, b"\x1bP0p\x05A\x1b\\");
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![0], 0, vec![], false, 'p'),
            Action::Put(0x05),
            Action::Put(b'A'),
            Action::Unhook,
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // CAN (0x18) during passthrough unhooks and returns to Ground
    parser.advance_bytes(&mut performer, b"\x1bP0pABC\x18");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![0], 0, vec![], false, 'p'),
            Action::Put(b'A'),
            Action::Put(b'B'),
            Action::Put(b'C'),
            Action::Unhook,
        ]
    );

    performer.actions.clear();
    // SUB (0x1A) during passthrough unhooks and returns to Ground
    parser.advance_bytes(&mut performer, b"\x1bP0p\x1a");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![0], 0, vec![], false, 'p'),
            Action::Unhook,
        ]
    );

    performer.actions.clear();
    // Non-ASCII byte during passthrough unhooks and returns to Ground
    parser.advance_bytes(&mut performer, b"\x1bP0p\x80");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![
            Action::Hook(vec![0], 0, vec![], false, 'p'),
            Action::Unhook,
        ]
    );
}

/// DcsIgnore consumes bytes until CAN, SUB, or ESC restart.
#[test]
fn dcs_ignore_state_transitions() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // DcsIgnore is a quiescent error state restored from checkpoints
    parser.state = State::DcsIgnore;
    parser.advance(&mut performer, b'a');
    parser.advance(&mut performer, b'b');
    assert_eq!(parser.state, State::DcsIgnore);

    // CAN resets to Ground
    parser.advance(&mut performer, 0x18);
    assert_eq!(parser.state, State::Ground);

    // SUB resets to Ground
    parser.state = State::DcsIgnore;
    parser.advance(&mut performer, 0x1A);
    assert_eq!(parser.state, State::Ground);

    // ESC transitions to Escape
    parser.state = State::DcsIgnore;
    parser.advance(&mut performer, 0x1B);
    assert_eq!(parser.state, State::Escape);
}

/// OscString decodes 4-byte UTF-8, preserves raw high bytes, and handles 8-bit ST.
#[test]
fn osc_string_4byte_utf8_continuation_and_invalids() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // 4-byte UTF-8 emoji in OSC title (0xF0..=0xF4 lead byte)
    parser.advance_bytes(&mut performer, b"\x1b]0;\xf0\x9f\xa6\x80\x07");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::OscDispatch(
            vec![b"0".to_vec(), "🦀".as_bytes().to_vec()],
            true
        )]
    );

    performer.actions.clear();
    // Stray continuation byte (0x80) when utf8_need == 0 pushed as raw byte
    parser.advance_bytes(&mut performer, b"\x1b]0;\x80\x07");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::OscDispatch(vec![b"0".to_vec(), vec![0x80]], true)]
    );

    performer.actions.clear();
    // 8-bit ST (0x9C) terminates OSC without bell flag
    parser.advance_bytes(&mut performer, b"\x1b]2;window\x9c");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::OscDispatch(
            vec![b"2".to_vec(), b"window".to_vec()],
            false
        )]
    );

    performer.actions.clear();
    // Invalid high byte >= 0x80 (e.g. 0xFF) pushed as raw byte
    parser.advance_bytes(&mut performer, b"\x1b]0;\xff\x07");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::OscDispatch(vec![b"0".to_vec(), vec![0xFF]], true)]
    );

    performer.actions.clear();
    // CAN (0x18) cancels OSC cleanly without dispatch
    parser.advance_bytes(&mut performer, b"\x1b]0;aborted\x18");
    assert_eq!(parser.state, State::Ground);
    assert!(performer.actions.is_empty());
}

/// SOS, PM, and APC buffers collect multi-byte UTF-8 and dispatch on ST.
#[test]
fn sos_pm_apc_comprehensive() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // APC with 2-byte, 3-byte, and 4-byte UTF-8, terminated by 7-bit ST (ESC \)
    let utf8_payload = "café € 🦀".as_bytes();
    let mut seq = b"\x1b_".to_vec();
    seq.extend_from_slice(utf8_payload);
    seq.extend_from_slice(b"\x1b\\");
    parser.advance_bytes(&mut performer, &seq);
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![
            Action::ApcDispatch(utf8_payload.to_vec()),
            Action::EscDispatch(vec![], false, b'\\'),
        ]
    );

    performer.actions.clear();
    // PM string terminated by 8-bit ST (0x9C)
    parser.advance_bytes(&mut performer, b"\x1b^privacy-data\x9c");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::ApcDispatch(b"privacy-data".to_vec())]
    );

    performer.actions.clear();
    // SOS string cancelled by CAN (0x18)
    parser.advance_bytes(&mut performer, b"\x1bXcancelled\x18");
    assert_eq!(parser.state, State::Ground);
    assert!(performer.actions.is_empty());

    performer.actions.clear();
    // APC with raw high bytes (>= 0x80)
    parser.advance_bytes(&mut performer, b"\x1b_\x80\xff\x9c");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::ApcDispatch(vec![0x80, 0xFF])]
    );
}

/// unhandled state variants like CsiIgnore fall back to Ground.
#[test]
fn unhandled_state_fallback() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // CsiIgnore is defined in State and restored by checkpoints, but advance falls through to Ground
    parser.state = State::CsiIgnore;
    parser.advance(&mut performer, b'A');
    assert_eq!(parser.state, State::Ground);
}

/// sequences with more than 16 intermediate bytes set ignore flag.
#[test]
fn intermediate_limit_sets_ignore() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // 17 intermediate bytes in CSI
    parser.advance_bytes(&mut performer, b"\x1b[ !\"#$%&'()*+,-./ !m");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(performer.actions.len(), 1);
    if let Action::CsiDispatch(_params, _sep, _inter, ignore, action) = &performer.actions[0] {
        assert_eq!(*action, 'm');
        assert!(*ignore, "more than 16 intermediates must set ignore");
    } else {
        panic!("expected CsiDispatch");
    }
}

/// numeric CSI parameter values saturate at u16::MAX instead of wrapping.
#[test]
fn param_u16_overflow_saturates() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    parser.advance_bytes(&mut performer, b"\x1b[999999999m");
    assert_eq!(parser.state, State::Ground);
    assert_eq!(
        performer.actions,
        vec![Action::CsiDispatch(vec![u16::MAX], 0, vec![], false, 'm')]
    );
}

/// invalid UTF-8 lead bytes and premature ASCII interruptions print replacement characters.
#[test]
fn ground_utf8_errors_and_recovery() {
    let mut parser = Parser::new();
    let mut performer = TestPerformer::default();

    // Invalid lead bytes 0xC0 and 0xFF produce replacement character
    parser.advance(&mut performer, 0xC0);
    parser.advance(&mut performer, 0xFF);
    assert_eq!(
        performer.actions,
        vec![Action::Print('\u{FFFD}'), Action::Print('\u{FFFD}')]
    );

    performer.actions.clear();
    // Interrupted 4-byte UTF-8 sequence resets utf8_need and processes ASCII byte immediately
    parser.advance(&mut performer, 0xF0);
    parser.advance(&mut performer, b'Z');
    assert_eq!(performer.actions, vec![Action::Print('Z')]);
}

/// Terminal end-to-end integration drives parser through Terminal::feed public API.
#[test]
fn terminal_end_to_end_integration() {
    let mut term = Terminal::new(80, 24);

    // Set title via OSC 0
    term.feed(b"\x1b]0;Coverage Title\x07");
    assert_eq!(term.title(), "Coverage Title");

    // SGR styling and text feed
    term.feed(b"\x1b[1;32mGreen\x1b[0m");
    assert_eq!(term.cursor(), (0, 5));

    // Move cursor with CSI H
    term.feed(b"\x1b[5;10H");
    assert_eq!(term.cursor(), (4, 9));

    // DCS query response (DECRQSS)
    term.feed(b"\x1bP$qm\x1b\\");
    let out = term.take_output();
    assert!(!out.is_empty());
}
