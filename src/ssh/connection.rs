/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use russh::client::AuthResult;
use russh::client::{self, KeyboardInteractiveAuthResponse};
use russh::keys::{PrivateKeyWithHashAlg, decode_secret_key};
use russh::{ChannelMsg, Disconnect, MethodKind};

use super::{SshAuth, SshConfig, SshEvents, SshPrompt};

/// Commands the owning thread accepts once a session is running.
pub(crate) enum Command {
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
                return Err("authentication was rejected".to_string());
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
pub(crate) async fn run(
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
