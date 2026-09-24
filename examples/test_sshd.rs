//! An ssh server for driving the app against, on the loopback.
//!
//! OpenSSH is the right thing to test the ordinary path against -- a real
//! shell, a real login -- but it cannot do two things this needs. It
//! validates passwords through PAM against real accounts, so a throwaway
//! sshd cannot accept a made-up one; and its shell echoes what you type
//! rather than saying what it received, so "the ⌃ key sent 0x03" is not a
//! question it can answer.
//!
//! This one accepts a password of your choosing, accepts any key listed in an
//! authorized_keys file, and runs a shell that names the bytes it is given.
//! That last part is the point: what the key row produces becomes visible
//! both in the engine's buffer and on the screen.
//!
//!     cargo run --features ssh --example test_sshd -- \
//!         --port 2230 --password hunter2 --authorized-keys keys.pub
//!
//! Prints `listening <port>` once it is up, so a caller need not poll.

use std::borrow::Cow;
use std::collections::HashSet;
use std::sync::Arc;

use russh::keys::{HashAlg, PublicKey};
use russh::server::{Auth, Handler as ServerHandler, Msg, Response, Server as _, Session};
use russh::{Channel, ChannelId, MethodKind, MethodSet};

#[derive(Clone, Default)]
struct Config {
    port: u16,
    password: Option<String>,
    mfa_password: Option<String>,
    mfa_code: Option<String>,
    mfa_device: Option<String>,
    /// Fingerprints, not keys: comparing what the client offered against a
    /// set of `SHA256:` strings avoids caring how each key type encodes.
    authorized: Arc<HashSet<String>>,
}

#[derive(Clone)]
struct TestServer {
    config: Config,
}

impl russh::server::Server for TestServer {
    type Handler = TestHandler;

    fn new_client(&mut self, _peer: Option<std::net::SocketAddr>) -> TestHandler {
        TestHandler {
            config: self.config.clone(),
            method: String::new(),
            primary_verified: false,
            mfa_round: 0,
        }
    }
}

struct TestHandler {
    config: Config,
    /// How this client got in, so the shell can say so and a test can tell
    /// "connected" from "connected the way I asked for".
    method: String,
    primary_verified: bool,
    mfa_round: u8,
}

impl ServerHandler for TestHandler {
    type Error = russh::Error;

    async fn auth_password(&mut self, user: &str, password: &str) -> Result<Auth, Self::Error> {
        if let (Some(expected), Some(_)) = (&self.config.mfa_password, &self.config.mfa_code) {
            if password == expected {
                self.primary_verified = true;
                self.method = format!("password + keyboard-interactive (user {user})");
                return Ok(Auth::Reject {
                    proceed_with_methods: Some(MethodSet::from(
                        &[MethodKind::KeyboardInteractive][..],
                    )),
                    partial_success: true,
                });
            }
            return Ok(Auth::Reject {
                proceed_with_methods: Some(MethodSet::from(&[MethodKind::Password][..])),
                partial_success: false,
            });
        }

        match &self.config.password {
            Some(expected) if password == expected => {
                self.method = format!("password (user {user})");
                Ok(Auth::Accept)
            }
            _ => Ok(Auth::Reject {
                proceed_with_methods: None,
                partial_success: false,
            }),
        }
    }

    async fn auth_keyboard_interactive<'a>(
        &'a mut self,
        user: &str,
        _submethods: &str,
        response: Option<Response<'a>>,
    ) -> Result<Auth, Self::Error> {
        let (Some(expected_password), Some(expected_code), Some(expected_device)) = (
            self.config.mfa_password.as_deref(),
            self.config.mfa_code.as_deref(),
            self.config.mfa_device.as_deref(),
        ) else {
            return Ok(Auth::UnsupportedMethod);
        };

        let Some(response) = response else {
            self.mfa_round = 0;
            let prompts = if self.primary_verified {
                vec![(Cow::Borrowed("Verification code: "), false)]
            } else {
                vec![
                    (Cow::Borrowed("Account password: "), false),
                    (Cow::Borrowed("Verification code: "), false),
                ]
            };
            return Ok(Auth::Partial {
                name: Cow::Borrowed("TakoCore test MFA"),
                instructions: Cow::Borrowed("Complete both verification rounds."),
                prompts: Cow::Owned(prompts),
            });
        };

        let answers: Vec<bytes::Bytes> = response.collect();
        match self.mfa_round {
            0 => {
                let correct = if self.primary_verified {
                    answers.len() == 1 && answers[0].as_ref() == expected_code.as_bytes()
                } else {
                    answers.len() == 2
                        && answers[0].as_ref() == expected_password.as_bytes()
                        && answers[1].as_ref() == expected_code.as_bytes()
                };
                if !correct {
                    return Ok(Auth::reject());
                }
                self.mfa_round = 1;
                Ok(Auth::Partial {
                    name: Cow::Borrowed("Device confirmation"),
                    instructions: Cow::Borrowed("Name the device completing sign-in."),
                    prompts: Cow::Owned(vec![(Cow::Borrowed("Device: "), true)]),
                })
            }
            1 if answers.len() == 1 && answers[0].as_ref() == expected_device.as_bytes() => {
                self.method = format!("keyboard-interactive MFA (user {user})");
                Ok(Auth::Accept)
            }
            _ => Ok(Auth::reject()),
        }
    }

    async fn auth_publickey(&mut self, user: &str, key: &PublicKey) -> Result<Auth, Self::Error> {
        let fingerprint = key.fingerprint(HashAlg::Sha256).to_string();
        if self.config.authorized.contains(&fingerprint) {
            self.method = format!("{} key (user {user})", key.algorithm());
            Ok(Auth::Accept)
        } else {
            Ok(Auth::Reject {
                proceed_with_methods: None,
                partial_success: false,
            })
        }
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
        term: &str,
        cols: u32,
        rows: u32,
        _pw: u32,
        _ph: u32,
        _modes: &[(russh::Pty, u32)],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        // Echoed so a test can check the app asked for the size it is drawing
        // at, rather than the default it was built with.
        let line: bytes::Bytes = format!("PTY {term} {cols}x{rows}\r\n").into_bytes().into();
        session.data(_channel, line)?;
        Ok(())
    }

    async fn window_change_request(
        &mut self,
        channel: ChannelId,
        cols: u32,
        rows: u32,
        _pw: u32,
        _ph: u32,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let line: bytes::Bytes = format!("RESIZE {cols}x{rows}\r\n").into_bytes().into();
        session.data(channel, line)?;
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let banner: bytes::Bytes = format!("AUTH {}\r\nTYPE SOMETHING\r\n", self.method)
            .into_bytes()
            .into();
        session.data(channel, banner)?;
        Ok(())
    }

    /// Says what arrived rather than echoing it.
    ///
    /// A terminal echoing its own input proves the round trip and nothing
    /// else; naming the bytes is what makes "⌃ then c sends 0x03, not the
    /// letter c" a thing you can see on a screenshot.
    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let hex = data
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<Vec<_>>()
            .join(" ");
        let printable: String = data
            .iter()
            .map(|&b| {
                if (0x20..0x7f).contains(&b) {
                    b as char
                } else {
                    '.'
                }
            })
            .collect();
        let line: bytes::Bytes = format!("GOT [{hex}] \"{printable}\"\r\n")
            .into_bytes()
            .into();
        session.data(channel, line)?;
        Ok(())
    }
}

fn main() {
    let mut config = Config::default();
    let mut authorized = HashSet::new();
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--port" => {
                config.port = args[i + 1].parse().expect("port");
                i += 2;
            }
            "--password" => {
                config.password = Some(args[i + 1].clone());
                i += 2;
            }
            "--mfa-password" => {
                config.mfa_password = Some(args[i + 1].clone());
                i += 2;
            }
            "--mfa-code" => {
                config.mfa_code = Some(args[i + 1].clone());
                i += 2;
            }
            "--mfa-device" => {
                config.mfa_device = Some(args[i + 1].clone());
                i += 2;
            }
            "--authorized-keys" => {
                let text = std::fs::read_to_string(&args[i + 1]).expect("authorized keys");
                for line in text.lines().filter(|l| !l.trim().is_empty()) {
                    let key = russh::keys::PublicKey::from_openssh(line).expect("public key");
                    authorized.insert(key.fingerprint(HashAlg::Sha256).to_string());
                }
                i += 2;
            }
            other => panic!("unknown argument {other}"),
        }
    }
    config.authorized = Arc::new(authorized);
    assert_eq!(
        config.mfa_password.is_some(),
        config.mfa_code.is_some(),
        "--mfa-password and --mfa-code must be supplied together"
    );
    if config.mfa_code.is_some() && config.mfa_device.is_none() {
        config.mfa_device = Some("iPhone".to_string());
    }

    let host_key = generate_host_key();
    let port = config.port;

    let runtime = tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("runtime");

    runtime.block_on(async move {
        let server_config = Arc::new(russh::server::Config {
            keys: vec![host_key],
            auth_rejection_time: std::time::Duration::from_millis(50),
            ..Default::default()
        });

        let listener = tokio::net::TcpListener::bind(("127.0.0.1", port))
            .await
            .expect("bind");
        println!("listening {}", listener.local_addr().unwrap().port());

        let mut server = TestServer { config };
        loop {
            let Ok((stream, addr)) = listener.accept().await else {
                continue;
            };
            let handler = server.new_client(Some(addr));
            let server_config = server_config.clone();
            tokio::spawn(async move {
                let _ = russh::server::run_stream(server_config, stream, handler).await;
            });
        }
    });
}

/// Generated by `ssh-keygen` rather than in process: `PrivateKey::random`
/// wants an RNG from the exact `rand_core` ssh-key was built against, and
/// chasing that version across the tree is a worse dependency than one
/// subprocess. A committed private key would be worse still, test-only or not.
fn generate_host_key() -> russh::keys::PrivateKey {
    let dir = std::env::temp_dir().join(format!("tako-test-sshd-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    let path = dir.join("host");

    let status = std::process::Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", ""])
        .arg("-f")
        .arg(&path)
        // Closed, not inherited: ssh-keygen prompts before overwriting, and an
        // inherited stdin turns that prompt into a hang with no output.
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .expect("run ssh-keygen");
    assert!(status.success(), "ssh-keygen failed");

    let key = russh::keys::PrivateKey::read_openssh_file(&path).expect("read host key");
    let _ = std::fs::remove_dir_all(&dir);
    key
}
