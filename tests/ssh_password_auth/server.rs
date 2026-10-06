/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::borrow::Cow;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use russh::server::{Auth, Handler as ServerHandler, Msg, Response, Session};
use russh::{Channel, ChannelId, MethodKind, MethodSet};

pub(crate) const GOOD_USER: &str = "alex";
pub(crate) const GOOD_PASSWORD: &str = "correct horse battery staple";
pub(crate) const CODE: &str = "424242";
pub(crate) const NEXT_CODE: &str = "135791";
pub(crate) const SERIAL: &str = "TOK-0001";
/// Echoed by the fake shell, so a test can tell "authenticated" from
/// "authenticated and actually got a shell".
pub(crate) const GREETING: &str = "TAKO_SHELL_READY";

// ── What the server asks ─────────────────────────────────────────────────────

/// One round of keyboard-interactive: what the server asks, and what it will
/// accept as the answer.
pub(crate) struct Round {
    pub(crate) name: &'static str,
    pub(crate) instructions: &'static str,
    /// The question, and whether the client may show what is typed.
    pub(crate) prompts: &'static [(&'static str, bool)],
    pub(crate) answers: &'static [&'static str],
}

/// The ordinary shape: one question, hidden.
pub(crate) const ONE_PROMPT: &[Round] = &[Round {
    name: "Two-factor",
    instructions: "Type the code from your phone.",
    prompts: &[("Verification code: ", false)],
    answers: &[CODE],
}];

/// Three questions at once, one of which the user is meant to see. A phone
/// that hides the token serial makes it unusable; one that shows the code
/// leaks it over a shoulder.
pub(crate) const THREE_PROMPTS: &[Round] = &[Round {
    name: "Login",
    instructions: "",
    prompts: &[
        ("Password: ", false),
        ("Verification code: ", false),
        ("Token serial: ", true),
    ],
    answers: &[GOOD_PASSWORD, CODE, SERIAL],
}];

/// Two rounds, because a server may keep asking -- a code, then a second one
/// from a different factor.
pub(crate) const TWO_ROUNDS: &[Round] = &[
    Round {
        name: "Two-factor",
        instructions: "Code from your phone.",
        prompts: &[("Verification code: ", false)],
        answers: &[CODE],
    },
    Round {
        name: "Two-factor",
        instructions: "Now the one from your token.",
        prompts: &[("Token code: ", false)],
        answers: &[NEXT_CODE],
    },
];

/// A round with nothing to ask -- RFC 4256 lets a server talk without asking,
/// and expects an answer with no responses in it, promptly.
pub(crate) const NOTICE_THEN_PROMPT: &[Round] = &[
    Round {
        name: "Notice",
        instructions: "Your password expires in three days.",
        prompts: &[],
        answers: &[],
    },
    Round {
        name: "Two-factor",
        instructions: "Code from your phone.",
        prompts: &[("Verification code: ", false)],
        answers: &[CODE],
    },
];

/// Nothing asked at all: the whole exchange is one empty round.
pub(crate) const NOTICE_ONLY: &[Round] = &[Round {
    name: "Notice",
    instructions: "Welcome.",
    prompts: &[],
    answers: &[],
}];

/// What the server will accept.
#[derive(Clone, Copy)]
pub(crate) enum Policy {
    Password,
    /// Refuses password and asks for keyboard-interactive instead, the way a
    /// host with 2FA-only login does.
    KeyboardInteractive(&'static [Round]),
    /// Takes the password as one factor, then asks.
    PasswordThenKeyboardInteractive(&'static [Round]),
    /// Takes the key as one factor, then asks.
    PublicKeyThenKeyboardInteractive(&'static [Round]),
}

impl Policy {
    fn script(self) -> Option<&'static [Round]> {
        match self {
            Policy::Password => None,
            Policy::KeyboardInteractive(script)
            | Policy::PasswordThenKeyboardInteractive(script)
            | Policy::PublicKeyThenKeyboardInteractive(script) => Some(script),
        }
    }
}

fn only(method: MethodKind) -> Option<MethodSet> {
    Some(MethodSet::from(&[method][..]))
}

/// Turns a scripted round into the question russh puts on the wire.
fn ask(round: &'static Round) -> Auth {
    Auth::Partial {
        name: Cow::Borrowed(round.name),
        instructions: Cow::Borrowed(round.instructions),
        prompts: Cow::Owned(
            round
                .prompts
                .iter()
                .map(|(text, echo)| (Cow::Borrowed(*text), *echo))
                .collect(),
        ),
    }
}

// ── The test server ──────────────────────────────────────────────────────────

#[derive(Clone)]
pub(crate) struct TestSshServer {
    pub(crate) policy: Policy,
    /// The one key `Policy::PublicKeyThenKeyboardInteractive` accepts.
    pub(crate) authorized: Option<Arc<russh::keys::ssh_key::PublicKey>>,
    /// Set when a client authenticated and asked for a shell.
    pub(crate) served: Arc<AtomicBool>,
    /// The dimensions from the initial PTY request.
    pub(crate) pty_size: Arc<Mutex<Option<(u32, u32)>>>,
}

impl russh::server::Server for TestSshServer {
    type Handler = TestSshHandler;

    fn new_client(&mut self, _peer: Option<std::net::SocketAddr>) -> TestSshHandler {
        TestSshHandler {
            policy: self.policy,
            authorized: self.authorized.clone(),
            round: 0,
            served: self.served.clone(),
            pty_size: self.pty_size.clone(),
        }
    }
}

pub(crate) struct TestSshHandler {
    policy: Policy,
    authorized: Option<Arc<russh::keys::ssh_key::PublicKey>>,
    /// Which scripted round this client is on.
    round: usize,
    served: Arc<AtomicBool>,
    pty_size: Arc<Mutex<Option<(u32, u32)>>>,
}

impl ServerHandler for TestSshHandler {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        match self.policy {
            Policy::Password => {
                if user == GOOD_USER && password == GOOD_PASSWORD {
                    Ok(Auth::Accept)
                } else {
                    Ok(Auth::reject())
                }
            }
            // Never wanted a password at all.
            Policy::KeyboardInteractive(_) => Ok(Auth::Reject {
                proceed_with_methods: only(MethodKind::KeyboardInteractive),
                partial_success: false,
            }),
            // The password was right and is not enough. This is the reject
            // that means "keep going", and telling it apart from a real
            // refusal is the whole point of `partial_success`.
            Policy::PasswordThenKeyboardInteractive(_) => {
                if user == GOOD_USER && password == GOOD_PASSWORD {
                    Ok(Auth::Reject {
                        proceed_with_methods: only(MethodKind::KeyboardInteractive),
                        partial_success: true,
                    })
                } else {
                    Ok(Auth::reject())
                }
            }
            Policy::PublicKeyThenKeyboardInteractive(_) => Ok(Auth::Reject {
                proceed_with_methods: only(MethodKind::PublicKey),
                partial_success: false,
            }),
        }
    }

    async fn auth_publickey(
        &mut self,
        user: &str,
        public_key: &russh::keys::ssh_key::PublicKey,
    ) -> Result<Auth, Self::Error> {
        let Some(authorized) = self.authorized.as_deref() else {
            return Ok(Auth::reject());
        };
        if user == GOOD_USER && public_key == authorized {
            Ok(Auth::Reject {
                proceed_with_methods: only(MethodKind::KeyboardInteractive),
                partial_success: true,
            })
        } else {
            Ok(Auth::reject())
        }
    }

    async fn auth_keyboard_interactive<'a>(
        &'a mut self,
        user: &str,
        _submethods: &str,
        response: Option<Response<'a>>,
    ) -> Result<Auth, Self::Error> {
        let Some(script) = self.policy.script() else {
            return Ok(Auth::reject());
        };
        if user != GOOD_USER {
            return Ok(Auth::reject());
        }

        let Some(response) = response else {
            // The opening request: ask the first thing.
            return Ok(match script.first() {
                Some(round) => ask(round),
                None => Auth::Accept,
            });
        };

        let given: Vec<Vec<u8>> = response.map(|bytes| bytes.to_vec()).collect();
        let round = &script[self.round];
        let right = given.len() == round.answers.len()
            && given
                .iter()
                .zip(round.answers)
                .all(|(got, want)| got.as_slice() == want.as_bytes());
        if !right {
            return Ok(Auth::reject());
        }

        self.round += 1;
        Ok(match script.get(self.round) {
            Some(round) => ask(round),
            None => Auth::Accept,
        })
    }

    async fn channel_open_session(
        &mut self,
        _channel: Channel<Msg>,
        reply: russh::server::ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        // Returning Ok is not acceptance: the handle has to be used, or the
        // client is told AdministrativelyProhibited.
        reply.accept().await;
        Ok(())
    }

    async fn pty_request(
        &mut self,
        _channel: ChannelId,
        _term: &str,
        cols: u32,
        rows: u32,
        _pw: u32,
        _ph: u32,
        _modes: &[(russh::Pty, u32)],
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        *self.pty_size.lock().unwrap() = Some((cols, rows));
        Ok(())
    }

    /// A shell that says one thing, which is all a transport test needs from
    /// the far end.
    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.served.store(true, Ordering::SeqCst);
        let greeting: bytes::Bytes = format!("{GREETING}\r\n").into_bytes().into();
        session.data(channel, greeting)?;
        Ok(())
    }
}
