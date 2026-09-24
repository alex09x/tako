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
use std::time::Duration;

use russh::client::AuthResult;
use russh::client::{self, KeyboardInteractiveAuthResponse};
use russh::keys::{decode_secret_key, PrivateKeyWithHashAlg};
use russh::{ChannelMsg, Disconnect, MethodKind};

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

/// Commands the owning thread accepts once a session is running.
enum Command {
    Send(Vec<u8>),
    Resize {
        cols: u32,
        rows: u32,
    },
    /// An answer to `SshEvents::on_keyboard_interactive`, or `None` for a
    /// refusal. Carried on the same channel as everything else so the
    /// authenticating task can wait on one thing.
    Challenge {
        challenge_id: u64,
        responses: Option<Vec<String>>,
    },
    Disconnect,
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

/// Bridges russh's handler callbacks to the host's.
struct Handler {
    events: Arc<dyn SshEvents>,
}

impl client::Handler for Handler {
    type Error = russh::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &russh::keys::ssh_key::PublicKey,
    ) -> Result<bool, Self::Error> {
        // The `SHA256:...` form, so a user can compare it against what
        // `ssh-keygen -lf` prints for the host.
        let fingerprint = server_public_key
            .fingerprint(russh::keys::HashAlg::Sha256)
            .to_string();
        let algorithm = server_public_key.algorithm().to_string();
        Ok(self.events.on_host_key(algorithm, fingerprint))
    }
}

/// What we are willing to negotiate, and in what order.
///
/// russh's default list is deliberately narrow -- it calls it "safe" and
/// leaves the NIST curves out on principle. That is a defensible position
/// for a library and the wrong one for a terminal, because a server offering
/// only `ecdh-sha2-nistp*` is not reachable at all, and "cannot connect" is a
/// worse outcome than "negotiated a curve we would not have picked first".
/// OpenSSH offers them by default; older RHEL hosts and appliances sometimes
/// offer nothing else.
///
/// They go on the end, so curve25519 -- and the post-quantum hybrid ahead of
/// it -- still win wherever the server knows them.
fn preferred_algorithms() -> russh::Preferred {
    let mut kex = russh::Preferred::DEFAULT.kex.to_vec();
    for name in [
        russh::kex::ECDH_SHA2_NISTP256,
        russh::kex::ECDH_SHA2_NISTP384,
        russh::kex::ECDH_SHA2_NISTP521,
    ] {
        if !kex.contains(&name) {
            kex.push(name);
        }
    }
    russh::Preferred {
        kex: std::borrow::Cow::Owned(kex),
        ..russh::Preferred::DEFAULT
    }
}

/// Runs the `keyboard-interactive` exchange to its end, asking the host each
/// question the server asks and feeding the answers back.
///
/// Returns `Ok` once the server is satisfied, or the reason it was not. An
/// empty reason means the user disconnected, which is not a failure.
///
/// Nothing here is logged. The prompts are the server's text and safe, the
/// answers are one-time codes and passwords and are not, and the difference
/// is not worth trusting a log level with.
async fn keyboard_interactive(
    handle: &mut client::Handle<Handler>,
    config: &SshConfig,
    events: &Arc<dyn SshEvents>,
    commands: &mut tokio::sync::mpsc::UnboundedReceiver<Command>,
    pty_size: &mut (u32, u32),
) -> Result<(), String> {
    let mut reply = handle
        .authenticate_keyboard_interactive_start(config.username.clone(), None)
        .await
        .map_err(|e| format!("authentication failed: {e}"))?;

    // Servers may ask over and over -- password, then code, then a new
    // password because the old one expired. Each round gets its own id.
    let mut challenge_id = 0u64;
    loop {
        let (name, instructions, prompts) = match reply {
            KeyboardInteractiveAuthResponse::Success => return Ok(()),
            KeyboardInteractiveAuthResponse::Failure { .. } => {
                return Err("authentication was rejected".to_string())
            }
            KeyboardInteractiveAuthResponse::InfoRequest {
                name,
                instructions,
                prompts,
            } => (name, instructions, prompts),
        };

        challenge_id += 1;
        let asked: Vec<SshPrompt> = prompts
            .into_iter()
            .map(|p| SshPrompt {
                prompt: p.prompt,
                echo: p.echo,
            })
            .collect();
        let wanted = asked.len();
        events.on_keyboard_interactive(challenge_id, name, instructions, asked);

        let answers = if wanted == 0 {
            // RFC 4256 §3.3: a request with no prompts is the server talking,
            // not asking, and the client answers it at once rather than
            // waiting for a user who has nothing to type. The host still got
            // the event above, so it can show what was said.
            Vec::new()
        } else {
            wait_for_answers(challenge_id, wanted, commands, pty_size).await?
        };

        reply = handle
            .authenticate_keyboard_interactive_respond(answers)
            .await
            .map_err(|e| format!("authentication failed: {e}"))?;
    }
}

/// Waits on the host for one round's answers, without holding the caller's
/// thread: the host replies whenever the user gets round to it.
async fn wait_for_answers(
    challenge_id: u64,
    wanted: usize,
    commands: &mut tokio::sync::mpsc::UnboundedReceiver<Command>,
    pty_size: &mut (u32, u32),
) -> Result<Vec<String>, String> {
    loop {
        match commands.recv().await {
            Some(Command::Challenge {
                challenge_id: id,
                responses,
            }) if id == challenge_id => {
                let Some(responses) = responses else {
                    return Err("keyboard-interactive was canceled".to_string());
                };
                if responses.len() != wanted {
                    // Counts, never the responses themselves.
                    return Err(format!(
                        "the host answered {} of {wanted} prompts",
                        responses.len()
                    ));
                }
                return Ok(responses);
            }
            Some(Command::Resize { cols, rows }) => {
                // A phone can rotate while its MFA sheet is open. There is no
                // channel to resize yet, so carry the newest geometry into
                // the initial PTY request instead of silently reverting to
                // the dimensions captured before authentication began.
                *pty_size = (cols, rows);
            }
            // An answer to a round that is over, or a keystroke typed at a
            // shell that does not exist yet. Neither is an error and neither
            // is worth acting on.
            Some(Command::Challenge { .. } | Command::Send(_)) => {}
            // The user closed the sheet, or the host dropped the session.
            Some(Command::Disconnect) | None => return Err(String::new()),
        }
    }
}

/// The whole life of one connection. Returns the reason it ended.
async fn run(
    config: SshConfig,
    events: Arc<dyn SshEvents>,
    mut commands: tokio::sync::mpsc::UnboundedReceiver<Command>,
    connected: &AtomicBool,
) -> String {
    let mut pty_size = (config.cols, config.rows);
    let client_config = Arc::new(client::Config {
        // A shell can sit idle for hours; killing it because nobody typed
        // would be a bug, not a feature. Keepalives detect a dead peer
        // instead.
        inactivity_timeout: None,
        keepalive_interval: Some(Duration::from_secs(30)),
        preferred: preferred_algorithms(),
        ..Default::default()
    });

    let handler = Handler {
        events: events.clone(),
    };
    let mut handle =
        match client::connect(client_config, (config.host.as_str(), config.port), handler).await {
            Ok(handle) => handle,
            Err(e) => return format!("could not connect: {e}"),
        };

    // Authentication.
    let authenticated = match &config.auth {
        SshAuth::Password { password } => {
            handle
                .authenticate_password(&config.username, password)
                .await
        }
        SshAuth::PrivateKey { pem, passphrase } => {
            let key = match decode_secret_key(pem, passphrase.as_deref()) {
                Ok(key) => key,
                Err(e) => return format!("could not read the private key: {e}"),
            };
            let hash = handle
                .best_supported_rsa_hash()
                .await
                .ok()
                .flatten()
                .flatten();
            handle
                .authenticate_publickey(
                    &config.username,
                    PrivateKeyWithHashAlg::new(Arc::new(key), hash),
                )
                .await
        }
    };
    match authenticated {
        Ok(AuthResult::Success) => {}
        // Not necessarily a no. A host with 2FA answers the password or the
        // key with "that was one factor, now do keyboard-interactive", which
        // is the same shape as a flat refusal apart from the method list --
        // and it is the same shape whether the first factor half-passed or
        // was never a factor the host wanted at all. Both continue here.
        Ok(AuthResult::Failure {
            remaining_methods, ..
        }) => {
            if !remaining_methods.contains(&MethodKind::KeyboardInteractive) {
                return "authentication was rejected".to_string();
            }
            if let Err(reason) =
                keyboard_interactive(&mut handle, &config, &events, &mut commands, &mut pty_size)
                    .await
            {
                // Says goodbye rather than dropping the socket, so the far
                // end logs a disconnect instead of a broken pipe. Best
                // effort: the reason we already have is the one to report.
                let _ = handle.disconnect(Disconnect::ByApplication, "", "en").await;
                return reason;
            }
        }
        Err(e) => return format!("authentication failed: {e}"),
    }

    // A resize or disconnect can arrive while russh is awaiting the server's
    // final authentication packet (including an automatic zero-prompt
    // round). Drain only commands that predate the channel so the very first
    // PTY has current geometry and a canceled connection never flashes a
    // shell. Input and stale challenge answers have no pre-shell recipient.
    loop {
        match commands.try_recv() {
            Ok(Command::Resize { cols, rows }) => pty_size = (cols, rows),
            Ok(Command::Disconnect) | Err(tokio::sync::mpsc::error::TryRecvError::Disconnected) => {
                let _ = handle.disconnect(Disconnect::ByApplication, "", "en").await;
                return String::new();
            }
            Ok(Command::Send(_) | Command::Challenge { .. }) => {}
            Err(tokio::sync::mpsc::error::TryRecvError::Empty) => break,
        }
    }

    // One channel, one shell, with a pty so the remote knows it is talking to
    // a terminal rather than a pipe -- without it there is no job control, no
    // line editing, and no SIGINT on ctrl+c.
    let channel = match handle.channel_open_session().await {
        Ok(channel) => channel,
        Err(e) => return format!("could not open a channel: {e}"),
    };
    if let Err(e) = channel
        .request_pty(true, &config.term, pty_size.0, pty_size.1, 0, 0, &[])
        .await
    {
        return format!("the server refused a pty: {e}");
    }
    if let Err(e) = channel.request_shell(true).await {
        return format!("the server refused a shell: {e}");
    }

    connected.store(true, Ordering::SeqCst);
    events.on_connected();

    let mut channel = channel;
    loop {
        tokio::select! {
            // Output from the remote.
            message = channel.wait() => {
                let Some(message) = message else {
                    return String::new();
                };
                match message {
                    ChannelMsg::Data { data } => events.on_data(data.to_vec()),
                    // stderr on a shell channel is rare but real; a terminal
                    // shows it in the same stream a local one would.
                    ChannelMsg::ExtendedData { data, .. } => events.on_data(data.to_vec()),
                    ChannelMsg::Eof | ChannelMsg::Close => return String::new(),
                    _ => {}
                }
            }
            // Input and control from the host.
            command = commands.recv() => {
                match command {
                    Some(Command::Send(data)) => {
                        if let Err(e) = channel.data(&data[..]).await {
                            return format!("could not send: {e}");
                        }
                    }
                    Some(Command::Resize { cols, rows }) => {
                        let _ = channel.window_change(cols, rows, 0, 0).await;
                    }
                    // Authentication is long over; a late answer to it has
                    // nowhere to go and must not become keystrokes.
                    Some(Command::Challenge { .. }) => {}
                    Some(Command::Disconnect) | None => {
                        let _ = handle
                            .disconnect(Disconnect::ByApplication, "", "en")
                            .await;
                        return String::new();
                    }
                }
            }
        }
    }
}
