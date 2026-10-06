/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! An SSH transport, so a phone can reach a shell.
//!
//! iOS forbids fork and exec, so there is no local shell on a phone and no
//! amount of terminal emulation changes that. A mobile terminal is a client
//! to something else or it is a demo. This is the something else.
//!
//! It lives in the core rather than in Swift for the same reason everything
//! else here does: it is bytes in and bytes out, and writing it once serves
//! both platforms. It also makes it testable by `cargo test`, which matters
//! more than it sounds -- the iOS view's own tests do not run on a Mac at
//! all, so anything only reachable from Swift is effectively untested.
//!
//! Feature-gated behind `ssh`, because it is the one part of this crate that
//! opens a socket, and the Go consumer and the conformance host have no
//! business linking a TLS-sized dependency tree.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

mod connection;

use connection::{Command, run};

/// How to prove who we are.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum SshAuth {
    /// A password, as typed.
    Password { password: String },
    /// An OpenSSH private key in its armoured text form, and the passphrase
    /// it was encrypted with if it was.
    PrivateKey {
        pem: String,
        passphrase: Option<String>,
    },
}

/// One question a server asked during keyboard-interactive authentication.
///
/// `echo` is the server's own instruction about the answer: false for a
/// password or a one-time code, true for something harmless like a username
/// or a token serial. Honouring it is the whole reason it crosses the FFI --
/// a host that shows every answer in the clear leaks codes over a shoulder,
/// and one that hides every answer makes the visible questions unusable.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct SshPrompt {
    pub prompt: String,
    pub echo: bool,
}

/// Everything needed to open one interactive shell.
#[derive(Debug, Clone, uniffi::Record)]
pub struct SshConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub auth: SshAuth,
    /// `TERM` for the remote side. The engine advertises xterm-256color.
    pub term: String,
    pub cols: u32,
    pub rows: u32,
}

/// What the host is told as a connection lives and dies.
///
/// Data arrives here rather than being polled, because the bytes are pushed
/// by the far end and a poll would either sleep on them or spin.
#[uniffi::export(callback_interface)]
pub trait SshEvents: Send + Sync {
    /// The server presented this host key. Returning false aborts the
    /// connection before authentication, so no password is ever sent to a
    /// host the user did not accept.
    ///
    /// `fingerprint` is the OpenSSH `SHA256:...` form, which is what a user
    /// can actually compare against `ssh-keygen -lf`.
    fn on_host_key(&self, algorithm: String, fingerprint: String) -> bool;

    /// The server is asking questions -- a one-time code, a new password, a
    /// confirmation tap. This is the `keyboard-interactive` method, which is
    /// how every 2FA host on earth talks to a client.
    ///
    /// It is a request for a reply, not a place to block: return at once and
    /// answer later, from whatever thread the user's answer arrives on, with
    /// `SshSession::answer_keyboard_interactive`, or refuse with
    /// `SshSession::cancel_keyboard_interactive`. The transport waits on its
    /// own thread meanwhile, so a phone can put a sheet on screen and keep
    /// drawing. Answering blocks nothing and answering never is a hang, so a
    /// host that cannot ask should cancel.
    ///
    /// `responses` must carry exactly one entry per prompt, in order.
    /// `challenge_id` names this round: a server may ask several times, and
    /// an answer tagged with a round that is over is ignored rather than
    /// misapplied to the next question.
    ///
    /// `name` and `instructions` are the server's own text, either possibly
    /// empty. An empty `prompts` is legal and means "nothing to ask" -- the
    /// transport answers that one itself, so a host need only show the text.
    ///
    /// Silence is a stall, not a refusal: a host with nowhere to put the
    /// question should cancel rather than say nothing.
    fn on_keyboard_interactive(
        &self,
        challenge_id: u64,
        name: String,
        instructions: String,
        prompts: Vec<SshPrompt>,
    );

    /// Authenticated, shell open, bytes about to flow.
    fn on_connected(&self);

    /// Output from the remote shell. Feed it straight to the engine.
    fn on_data(&self, data: Vec<u8>);

    /// The connection ended. `reason` is empty for a clean close.
    fn on_closed(&self, reason: String);
}

/// One SSH connection carrying one interactive shell.
///
/// The connection owns a thread with its own single-threaded runtime. The
/// alternative -- exposing futures across the FFI -- would put an async
/// runtime in every host that links this, for one socket.
#[derive(uniffi::Object)]
pub struct SshSession {
    commands: Mutex<Option<tokio::sync::mpsc::UnboundedSender<Command>>>,
    connected: Arc<AtomicBool>,
}

#[uniffi::export]
impl SshSession {
    /// Opens a connection and returns immediately. Progress and failure both
    /// arrive through `events`; nothing here blocks the caller's thread,
    /// because on a phone that thread is the one drawing.
    #[uniffi::constructor]
    pub fn connect(config: SshConfig, events: Box<dyn SshEvents>) -> Arc<Self> {
        // russh moves the handler into its own task, so it has to own the
        // callbacks rather than borrow them.
        let events: Arc<dyn SshEvents> = Arc::from(events);
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        let connected = Arc::new(AtomicBool::new(false));

        let session = Arc::new(Self {
            commands: Mutex::new(Some(tx)),
            connected: connected.clone(),
        });

        std::thread::Builder::new()
            .name(format!("ssh-{}", config.host))
            .spawn(move || {
                let runtime = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(runtime) => runtime,
                    Err(e) => {
                        events.on_closed(format!("could not start the runtime: {e}"));
                        return;
                    }
                };
                let reason = runtime.block_on(run(config, events.clone(), rx, &connected));
                connected.store(false, Ordering::SeqCst);
                events.on_closed(reason);
            })
            .expect("spawn ssh thread");

        session
    }

    /// True between `on_connected` and `on_closed`.
    pub fn is_connected(&self) -> bool {
        self.connected.load(Ordering::SeqCst)
    }

    /// Sends keystrokes. Silently dropped once the connection is gone, which
    /// is the same thing a closed pty does.
    pub fn send(&self, data: Vec<u8>) {
        self.dispatch(Command::Send(data));
    }

    /// Tells the remote its terminal changed size.
    pub fn resize(&self, cols: u32, rows: u32) {
        self.dispatch(Command::Resize { cols, rows });
    }

    /// Answers the keyboard-interactive challenge that arrived with this
    /// `challenge_id`, with one response per prompt, in the order the
    /// prompts came. Safe to call from any thread, including the one that
    /// runs the UI: it hands the answers over and returns.
    ///
    /// A stale `challenge_id` -- an answer to a round the server has already
    /// moved past -- is dropped rather than applied to the current question,
    /// so a slow user cannot have last round's code sent as this round's
    /// password. A wrong number of responses ends the connection with a
    /// reason instead of sending a half-filled form.
    pub fn answer_keyboard_interactive(&self, challenge_id: u64, responses: Vec<String>) {
        self.dispatch(Command::Challenge {
            challenge_id,
            responses: Some(responses),
        });
    }

    /// Refuses the challenge with this `challenge_id`. Nothing is sent to the
    /// server and the connection ends; this is the "cancel" on the sheet.
    pub fn cancel_keyboard_interactive(&self, challenge_id: u64) {
        self.dispatch(Command::Challenge {
            challenge_id,
            responses: None,
        });
    }

    /// Closes the connection. Idempotent.
    pub fn disconnect(&self) {
        self.dispatch(Command::Disconnect);
        *self.commands.lock().unwrap() = None;
    }
}

impl SshSession {
    fn dispatch(&self, command: Command) {
        if let Some(tx) = self.commands.lock().unwrap().as_ref() {
            let _ = tx.send(command);
        }
    }
}
