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

/// The common real-world shape: the password is right and is only the first
/// factor. The transport has to read "rejected, partially" as "keep going".
#[test]
fn a_password_that_half_succeeds_continues_into_the_questions() {
    let server = Fixture::start(Policy::PasswordThenKeyboardInteractive(ONE_PROMPT));
    let attempt = server.attempt_with(GOOD_USER, password(GOOD_PASSWORD), answering(&[&[CODE]]));

    let out = attempt
        .outcome
        .expect("partial password auth did not continue");
    assert!(out.contains(GREETING));
    assert_eq!(attempt.asked.len(), 1);
}

/// Rotation while an MFA sheet is visible happens before a channel exists.
/// The resize must become the initial PTY geometry rather than being dropped
/// and leaving the remote shell at the pre-authentication dimensions.
#[test]
fn a_resize_during_a_challenge_becomes_the_initial_pty_size() {
    let server = Fixture::start(Policy::PasswordThenKeyboardInteractive(ONE_PROMPT));
    let attempt = server.attempt_with(
        GOOD_USER,
        password(GOOD_PASSWORD),
        Box::new(|challenge: &Challenge, session: &SshSession| {
            session.resize(132, 47);
            session.answer_keyboard_interactive(challenge.id, vec![CODE.to_string()]);
        }),
    );

    let out = attempt.outcome.expect("MFA after a rotation failed");
    assert!(out.contains(GREETING));
    assert_eq!(
        *server.pty_size.lock().unwrap(),
        Some((132, 47)),
        "the pre-authentication size was used after the phone rotated"
    );
}

/// The same, for a key. Keys are the other half of the app's form and the
/// half where 2FA is most common.
#[test]
fn a_key_that_half_succeeds_continues_into_the_questions() {
    let server = Fixture::start(Policy::PublicKeyThenKeyboardInteractive(ONE_PROMPT));
    let attempt = server.attempt_with(GOOD_USER, server.key(), answering(&[&[CODE]]));

    let out = attempt.outcome.expect("partial key auth did not continue");
    assert!(out.contains(GREETING));
    assert!(server.served.load(Ordering::SeqCst));
}

/// A late answer to a round the server has moved past must be dropped, not
/// applied to the question on screen now -- otherwise a slow user sends last
/// round's code as this round's password.
#[test]
fn an_answer_to_a_finished_round_is_ignored() {
    let server = Fixture::start(Policy::KeyboardInteractive(TWO_ROUNDS));
    let attempt = server.attempt_with(
        GOOD_USER,
        password(GOOD_PASSWORD),
        Box::new(|challenge: &Challenge, session: &SshSession| {
            // An answer tagged with a round that is not this one.
            session.answer_keyboard_interactive(challenge.id + 100, vec!["stale".to_string()]);
            let answer = if challenge.id == 1 { CODE } else { NEXT_CODE };
            session.answer_keyboard_interactive(challenge.id, vec![answer.to_string()]);
        }),
    );

    let out = attempt
        .outcome
        .expect("a stale answer derailed a live challenge");
    assert!(out.contains(GREETING));
    assert_eq!(attempt.asked.len(), 2);
}

// ── Keyboard-interactive: the answers are wrong, or never come ───────────────

#[test]
fn a_wrong_answer_is_rejected_and_no_shell_opens() {
    let server = Fixture::start(Policy::KeyboardInteractive(ONE_PROMPT));
    let attempt = server.attempt_with(
        GOOD_USER,
        password(GOOD_PASSWORD),
        answering(&[&["000000"]]),
    );

    let reason = attempt.outcome.expect_err("a wrong code was accepted");
    assert!(!reason.is_empty(), "rejection has to say something");
    assert!(
        !server.served.load(Ordering::SeqCst),
        "a shell was opened anyway"
    );
}

/// Right first round, wrong second. Getting one factor right must not carry
/// the login the rest of the way.
#[test]
fn a_wrong_answer_in_a_later_round_still_fails() {
    let server = Fixture::start(Policy::KeyboardInteractive(TWO_ROUNDS));
    let attempt = server.attempt_with(
        GOOD_USER,
        password(GOOD_PASSWORD),
        answering(&[&[CODE], &["000000"]]),
    );

    assert!(
        attempt.outcome.is_err(),
        "a wrong second factor was accepted"
    );
    assert_eq!(attempt.asked.len(), 2, "the second round was never asked");
    assert!(!server.served.load(Ordering::SeqCst));
}

/// The user closed the sheet. Nothing is sent, and the connection ends
/// saying why rather than sitting there.
#[test]
fn cancelling_ends_the_connection_without_answering() {
    let server = Fixture::start(Policy::KeyboardInteractive(ONE_PROMPT));
    let attempt = server.attempt_with(
        GOOD_USER,
        password(GOOD_PASSWORD),
        Box::new(|challenge: &Challenge, session: &SshSession| {
            session.cancel_keyboard_interactive(challenge.id);
        }),
    );

    let reason = attempt
        .outcome
        .expect_err("cancelling let the login through");
    assert!(
        reason.contains("cancel"),
        "cancelling should say so, said {reason:?}"
    );
    assert!(!server.served.load(Ordering::SeqCst));
}

/// The other way a user walks away: closing the session outright while the
/// question is on screen.
#[test]
fn disconnecting_mid_challenge_ends_it_cleanly() {
    let server = Fixture::start(Policy::KeyboardInteractive(ONE_PROMPT));
    let attempt = server.attempt_with(
        GOOD_USER,
        password(GOOD_PASSWORD),
        Box::new(|_: &Challenge, session: &SshSession| session.disconnect()),
    );

    assert!(
        attempt.outcome.is_err(),
        "disconnecting during a challenge still opened a shell"
    );
    assert!(!server.served.load(Ordering::SeqCst));
    assert_eq!(attempt.asked.len(), 1);
}

/// A host that answers a three-prompt round with one string is a host bug.
/// Sending it anyway would half-fill the server's form; the connection ends
/// with a count -- never the responses themselves.
#[test]
fn a_short_answer_is_refused_rather_than_half_sent() {
    let server = Fixture::start(Policy::KeyboardInteractive(THREE_PROMPTS));
    let attempt = server.attempt_with(
        GOOD_USER,
        password(GOOD_PASSWORD),
        answering(&[&[GOOD_PASSWORD]]),
    );

    let reason = attempt.outcome.expect_err("a short answer was sent anyway");
    assert!(
        reason.contains("1 of 3"),
        "should say what was missing, said {reason:?}"
    );
    assert!(
        !reason.contains(GOOD_PASSWORD),
        "the reason leaked an answer"
    );
    assert!(!server.served.load(Ordering::SeqCst));
}

/// Nobody answers. The transport must wait -- not fail, not connect, not spin
/// -- until the host says something, which is what makes it safe to put the
/// question in front of a user who is looking for their phone.
#[test]
fn an_unanswered_question_waits_instead_of_failing() {
    let server = Fixture::start(Policy::KeyboardInteractive(ONE_PROMPT));
    let recorder = Arc::new(Recorder::default());
    let session = SshSession::connect(
        SshConfig {
            host: "127.0.0.1".to_string(),
            port: server.port,
            username: GOOD_USER.to_string(),
            auth: password(GOOD_PASSWORD),
            term: "xterm-256color".to_string(),
            cols: 80,
            rows: 24,
        },
        Box::new(Events(recorder.clone())),
    );

    // Long enough that a transport which gave up would have.
    let until = Instant::now() + Duration::from_secs(5);
    while Instant::now() < until {
        assert!(
            recorder.closed.lock().unwrap().is_none(),
            "gave up on an unanswered question"
        );
        assert!(!recorder.connected.load(Ordering::SeqCst), "let itself in");
        std::thread::sleep(Duration::from_millis(50));
    }
    assert_eq!(recorder.asked.lock().unwrap().len(), 1, "never asked");

    // And it is still listening: telling it to go away works.
    session.disconnect();
    let deadline = Instant::now() + Duration::from_secs(5);
    while recorder.closed.lock().unwrap().is_none() {
        assert!(Instant::now() < deadline, "did not close when told to");
        std::thread::sleep(Duration::from_millis(20));
    }
    assert!(!server.served.load(Ordering::SeqCst));
}

/// A server that wants keyboard-interactive from a client answering with a
/// key still gets asked -- and a host that refuses is told no, clearly, not
/// left hanging.
#[test]
fn a_host_that_cannot_ask_gets_a_reason_not_a_hang() {
    let server = Fixture::start(Policy::KeyboardInteractive(ONE_PROMPT));
    let started = Instant::now();
    let attempt = server.attempt_with(
        GOOD_USER,
        password(GOOD_PASSWORD),
        Box::new(|challenge: &Challenge, session: &SshSession| {
            session.cancel_keyboard_interactive(challenge.id);
        }),
    );

    assert!(attempt.outcome.is_err());
    assert!(
        started.elapsed() < Duration::from_secs(20),
        "took {:?} to report it",
        started.elapsed()
    );
}
