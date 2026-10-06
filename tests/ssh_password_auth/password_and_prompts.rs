/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::fixture::*;
use super::server::*;
use std::sync::atomic::Ordering;

#[test]
fn a_correct_password_opens_a_shell() {
    let server = Fixture::start(Policy::Password);
    let out = server
        .attempt(GOOD_USER, password(GOOD_PASSWORD))
        .expect("password auth failed");

    assert!(
        out.contains(GREETING),
        "authenticated but got no shell: {out:?}"
    );
    assert!(server.served.load(Ordering::SeqCst));
}

#[test]
fn a_wrong_password_is_rejected_and_reported() {
    let server = Fixture::start(Policy::Password);
    let result = server.attempt(GOOD_USER, password("hunter2"));

    let reason = result.expect_err("a wrong password was accepted");
    assert!(!reason.is_empty(), "rejection has to say something");
    assert!(
        !server.served.load(Ordering::SeqCst),
        "a shell was opened anyway"
    );
}

#[test]
fn an_unknown_user_is_rejected() {
    let server = Fixture::start(Policy::Password);
    let result = server.attempt("nobody", password(GOOD_PASSWORD));

    assert!(result.is_err(), "an unknown user was accepted");
}

#[test]
fn an_empty_password_is_rejected_rather_than_skipped() {
    // An empty string must be sent and refused, not treated as "no auth".
    let server = Fixture::start(Policy::Password);
    let result = server.attempt(GOOD_USER, password(""));

    assert!(result.is_err(), "an empty password was accepted");
}

#[test]
fn a_password_with_unicode_and_spaces_survives_the_wire() {
    // Phone keyboards produce both, and a mangled password fails in a way
    // that looks like a wrong one.
    let server = Fixture::start(Policy::Password);
    let out = server
        .attempt(GOOD_USER, password(GOOD_PASSWORD))
        .expect("a password with spaces failed");
    assert!(out.contains(GREETING));
}

// ── Keyboard-interactive: the answers are right ──────────────────────────────

/// A host with 2FA-only login: the password is not even wanted, and the
/// whole session hangs on one question the transport cannot answer itself.
#[test]
fn a_keyboard_interactive_only_host_opens_a_shell_when_answered() {
    let server = Fixture::start(Policy::KeyboardInteractive(ONE_PROMPT));
    let attempt = server.attempt_with(GOOD_USER, password(GOOD_PASSWORD), answering(&[&[CODE]]));

    let out = attempt.outcome.expect("keyboard-interactive auth failed");
    assert!(out.contains(GREETING), "answered but got no shell: {out:?}");
    assert!(server.served.load(Ordering::SeqCst));

    assert_eq!(attempt.asked.len(), 1, "asked {:?}", attempt.asked);
    let challenge = &attempt.asked[0];
    assert_eq!(challenge.name, "Two-factor");
    assert_eq!(challenge.instructions, "Type the code from your phone.");
    assert_eq!(challenge.prompts.len(), 1);
    assert_eq!(challenge.prompts[0].prompt, "Verification code: ");
    assert!(!challenge.prompts[0].echo, "a code must not be echoed");
}

/// Several questions in one round, and the echo flag the server set for each.
#[test]
fn every_prompt_crosses_with_its_own_echo_flag() {
    let server = Fixture::start(Policy::KeyboardInteractive(THREE_PROMPTS));
    let attempt = server.attempt_with(
        GOOD_USER,
        password(GOOD_PASSWORD),
        answering(&[&[GOOD_PASSWORD, CODE, SERIAL]]),
    );

    let out = attempt.outcome.expect("three-prompt round failed");
    assert!(out.contains(GREETING));

    let prompts = &attempt.asked[0].prompts;
    let seen: Vec<(&str, bool)> = prompts
        .iter()
        .map(|p| (p.prompt.as_str(), p.echo))
        .collect();
    assert_eq!(
        seen,
        vec![
            ("Password: ", false),
            ("Verification code: ", false),
            ("Token serial: ", true),
        ],
        "prompt text or echo visibility was lost crossing the FFI"
    );
}

/// Servers ask more than once. Each round must arrive on its own, be answered
/// on its own, and carry its own id.
#[test]
fn a_second_round_of_questions_is_asked_and_answered() {
    let server = Fixture::start(Policy::KeyboardInteractive(TWO_ROUNDS));
    let attempt = server.attempt_with(
        GOOD_USER,
        password(GOOD_PASSWORD),
        answering(&[&[CODE], &[NEXT_CODE]]),
    );

    let out = attempt.outcome.expect("multi-round auth failed");
    assert!(out.contains(GREETING), "answered both rounds, no shell");
    assert_eq!(attempt.asked.len(), 2, "asked {:?}", attempt.asked);
    assert_eq!(attempt.asked[0].prompts[0].prompt, "Verification code: ");
    assert_eq!(attempt.asked[1].prompts[0].prompt, "Token code: ");
    assert_ne!(
        attempt.asked[0].id, attempt.asked[1].id,
        "two rounds shared an id, so an answer could land on the wrong one"
    );
}

/// A round with no prompts is the server talking, not asking. RFC 4256 says
/// answer it at once -- waiting for a user with nothing to type is a hang.
#[test]
fn a_round_with_no_prompts_is_answered_without_the_user() {
    let server = Fixture::start(Policy::KeyboardInteractive(NOTICE_THEN_PROMPT));
    // The plan only ever answers a round with prompts in it; if the transport
    // waited for the empty one this deadlocks and the test times out.
    let attempt = server.attempt_with(
        GOOD_USER,
        password(GOOD_PASSWORD),
        Box::new(|challenge: &Challenge, session: &SshSession| {
            if challenge.prompts.is_empty() {
                return;
            }
            session.answer_keyboard_interactive(challenge.id, vec![CODE.to_string()]);
        }),
    );

    let out = attempt.outcome.expect("an empty round stalled the login");
    assert!(out.contains(GREETING));
    // The text still reached the host, which is the other half of RFC 4256:
    // show what was said even though nothing was asked.
    assert_eq!(attempt.asked.len(), 2);
    assert!(attempt.asked[0].prompts.is_empty());
    assert_eq!(
        attempt.asked[0].instructions,
        "Your password expires in three days."
    );
}

/// The degenerate case: asked nothing at all, and let in.
#[test]
fn an_exchange_of_only_notices_still_authenticates() {
    let server = Fixture::start(Policy::KeyboardInteractive(NOTICE_ONLY));
    let attempt = server.attempt_with(
        GOOD_USER,
        password(GOOD_PASSWORD),
        Box::new(|_: &Challenge, _: &SshSession| {}),
    );

    let out = attempt.outcome.expect("an empty exchange failed");
    assert!(out.contains(GREETING));
    assert!(server.served.load(Ordering::SeqCst));
}
