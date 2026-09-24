// Password and challenge/response authentication, against a server that
// actually checks the answers.
//
// This needed its own file and its own server. OpenSSH validates passwords
// through PAM against real accounts, so a throwaway sshd cannot accept a
// made-up one -- which is why every earlier "password" test aimed at a dead
// port and proved nothing about passwords at all. The app offers password
// auth in its form, so "nothing" was the wrong amount of coverage.
//
// The server here is russh's own, in-process: it accepts one password, one
// key, and a scripted set of keyboard-interactive rounds, and rejects
// everything else. No sshd, no accounts, no network beyond the loopback.
//
// The keyboard-interactive half is the interesting one. The transport cannot
// answer a server's questions itself -- only the user knows the code -- so it
// raises them through `SshEvents` and waits for `SshSession` to be told the
// answers. These tests drive both ends of that: the server asks, the "host"
// answers from a thread that is not the one waiting, and the shell either
// opens or does not.

#![cfg(feature = "ssh")]

use std::borrow::Cow;
use std::sync::atomic::{AtomicBool, AtomicU16, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use russh::server::{Auth, Handler as ServerHandler, Msg, Response, Server as _, Session};
use russh::{Channel, ChannelId, MethodKind, MethodSet};
use tako_core::ssh::{SshAuth, SshConfig, SshEvents, SshPrompt, SshSession};

const GOOD_USER: &str = "alex";
const GOOD_PASSWORD: &str = "correct horse battery staple";
const CODE: &str = "424242";
const NEXT_CODE: &str = "135791";
const SERIAL: &str = "TOK-0001";
/// Echoed by the fake shell, so a test can tell "authenticated" from
/// "authenticated and actually got a shell".
const GREETING: &str = "TAKO_SHELL_READY";

// ── What the server asks ─────────────────────────────────────────────────────

/// One round of keyboard-interactive: what the server asks, and what it will
/// accept as the answer.
struct Round {
    name: &'static str,
    instructions: &'static str,
    /// The question, and whether the client may show what is typed.
    prompts: &'static [(&'static str, bool)],
    answers: &'static [&'static str],
}

/// The ordinary shape: one question, hidden.
const ONE_PROMPT: &[Round] = &[Round {
    name: "Two-factor",
    instructions: "Type the code from your phone.",
    prompts: &[("Verification code: ", false)],
    answers: &[CODE],
}];

/// Three questions at once, one of which the user is meant to see. A phone
/// that hides the token serial makes it unusable; one that shows the code
/// leaks it over a shoulder.
const THREE_PROMPTS: &[Round] = &[Round {
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
const TWO_ROUNDS: &[Round] = &[
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
const NOTICE_THEN_PROMPT: &[Round] = &[
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
const NOTICE_ONLY: &[Round] = &[Round {
    name: "Notice",
    instructions: "Welcome.",
    prompts: &[],
    answers: &[],
}];

/// What the server will accept.
#[derive(Clone, Copy)]
enum Policy {
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
struct TestSshServer {
    policy: Policy,
    /// The one key `Policy::PublicKeyThenKeyboardInteractive` accepts.
    authorized: Option<Arc<russh::keys::ssh_key::PublicKey>>,
    /// Set when a client authenticated and asked for a shell.
    served: Arc<AtomicBool>,
    /// The dimensions from the initial PTY request.
    pty_size: Arc<Mutex<Option<(u32, u32)>>>,
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

struct TestSshHandler {
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

// ── The host side ────────────────────────────────────────────────────────────

/// One question the transport passed up, as the host saw it.
#[derive(Clone, Debug)]
struct Challenge {
    id: u64,
    name: String,
    instructions: String,
    prompts: Vec<SshPrompt>,
}

#[derive(Default)]
struct Recorder {
    connected: AtomicBool,
    data: Mutex<Vec<u8>>,
    closed: Mutex<Option<String>>,
    /// Everything that was ever asked, in order.
    asked: Mutex<Vec<Challenge>>,
    /// Asked but not yet handed to the plan.
    unserved: Mutex<Vec<Challenge>>,
}

impl Recorder {
    fn take_unserved(&self) -> Vec<Challenge> {
        std::mem::take(&mut *self.unserved.lock().unwrap())
    }
}

struct Events(Arc<Recorder>);

impl SshEvents for Events {
    fn on_host_key(&self, _algorithm: String, _fingerprint: String) -> bool {
        true
    }

    /// Records and returns. Answering from here would be the bug this whole
    /// design exists to avoid: on a phone this call arrives on the transport's
    /// thread and the answer comes from the user, much later.
    fn on_keyboard_interactive(
        &self,
        challenge_id: u64,
        name: String,
        instructions: String,
        prompts: Vec<SshPrompt>,
    ) {
        let challenge = Challenge {
            id: challenge_id,
            name,
            instructions,
            prompts,
        };
        self.0.asked.lock().unwrap().push(challenge.clone());
        self.0.unserved.lock().unwrap().push(challenge);
    }

    fn on_connected(&self) {
        self.0.connected.store(true, Ordering::SeqCst);
    }
    fn on_data(&self, data: Vec<u8>) {
        self.0.data.lock().unwrap().extend_from_slice(&data);
    }
    fn on_closed(&self, reason: String) {
        *self.0.closed.lock().unwrap() = Some(reason);
    }
}

/// How the host answers what it is asked. Called from the test's own thread,
/// never from the callback, because that is how a real host works.
type Plan = Box<dyn Fn(&Challenge, &SshSession) + Send>;

/// A host that is never asked anything.
fn unasked() -> Plan {
    Box::new(|challenge, _| panic!("nothing should have been asked, got {challenge:?}"))
}

/// A host that answers each round from a script, in order.
fn answering(rounds: &'static [&'static [&'static str]]) -> Plan {
    Box::new(move |challenge, session| {
        let round = rounds
            .get((challenge.id - 1) as usize)
            .unwrap_or_else(|| panic!("asked {} times, script has {}", challenge.id, rounds.len()));
        let answers = round.iter().map(|s| s.to_string()).collect();
        session.answer_keyboard_interactive(challenge.id, answers);
    })
}

/// What one connection did.
struct Attempt {
    /// The screen on success, the reason on failure.
    outcome: Result<String, String>,
    asked: Vec<Challenge>,
}

// ── The fixture ──────────────────────────────────────────────────────────────

/// A running server, on its own port, stopped when dropped.
struct Fixture {
    port: u16,
    served: Arc<AtomicBool>,
    /// The private key the client should use, when the policy wants one.
    client_key: Option<String>,
    pty_size: Arc<Mutex<Option<(u32, u32)>>>,
    handle: tokio::runtime::Runtime,
    stop: Arc<AtomicBool>,
}

impl Fixture {
    fn start(policy: Policy) -> Fixture {
        let served = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let port = Arc::new(AtomicU16::new(0));
        let pty_size = Arc::new(Mutex::new(None));

        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("runtime");

        // Generated by ssh-keygen rather than in-process: `PrivateKey::random`
        // wants an RNG from the exact `rand_core` ssh-key was built against,
        // and chasing that version across the tree is a worse dependency than
        // one subprocess. Committing a fixed private key would be worse still,
        // test-only or not.
        let key = generate_key();

        // Only the key-first policy needs a client key; the others would pay
        // for a second ssh-keygen and never offer it.
        let (client_key, authorized) = match policy {
            Policy::PublicKeyThenKeyboardInteractive(_) => {
                let pem = generate_key_pem();
                let parsed = russh::keys::decode_secret_key(&pem, None).expect("decode key");
                (Some(pem), Some(Arc::new(parsed.public_key().clone())))
            }
            _ => (None, None),
        };

        let config = Arc::new(russh::server::Config {
            keys: vec![key],
            auth_rejection_time: std::time::Duration::from_millis(50),
            ..Default::default()
        });

        let listen_served = served.clone();
        let listen_port = port.clone();
        let listen_stop = stop.clone();
        let listen_pty_size = pty_size.clone();
        runtime.spawn(async move {
            let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
                .await
                .expect("bind");
            listen_port.store(listener.local_addr().unwrap().port(), Ordering::SeqCst);

            let mut server = TestSshServer {
                policy,
                authorized,
                served: listen_served,
                pty_size: listen_pty_size,
            };
            loop {
                if listen_stop.load(Ordering::SeqCst) {
                    return;
                }
                let Ok(Ok((stream, addr))) =
                    tokio::time::timeout(Duration::from_millis(200), listener.accept()).await
                else {
                    continue;
                };
                let handler = server.new_client(Some(addr));
                let config = config.clone();
                tokio::spawn(async move {
                    let _ = russh::server::run_stream(config, stream, handler).await;
                });
            }
        });

        // The port is only known once the listener is up.
        let deadline = Instant::now() + Duration::from_secs(5);
        while port.load(Ordering::SeqCst) == 0 && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(10));
        }

        Fixture {
            port: port.load(Ordering::SeqCst),
            served,
            client_key,
            pty_size,
            handle: runtime,
            stop,
        }
    }

    /// The key auth for the policy that authorised one.
    fn key(&self) -> SshAuth {
        SshAuth::PrivateKey {
            pem: self
                .client_key
                .clone()
                .expect("no client key was generated"),
            passphrase: None,
        }
    }

    /// Connects with the given auth, answering nothing, and reports what
    /// happened.
    fn attempt(&self, user: &str, auth: SshAuth) -> Result<String, String> {
        self.attempt_with(user, auth, unasked()).outcome
    }

    /// Connects, letting `plan` answer whatever the server asks.
    fn attempt_with(&self, user: &str, auth: SshAuth, plan: Plan) -> Attempt {
        let recorder = Arc::new(Recorder::default());
        let session = SshSession::connect(
            SshConfig {
                host: "127.0.0.1".to_string(),
                port: self.port,
                username: user.to_string(),
                auth,
                term: "xterm-256color".to_string(),
                cols: 80,
                rows: 24,
            },
            Box::new(Events(recorder.clone())),
        );

        let outcome = self.pump(&session, &recorder, &plan, Duration::from_secs(15));
        Attempt {
            outcome,
            asked: recorder.asked.lock().unwrap().clone(),
        }
    }

    /// Serves challenges and waits for the connection to settle one way or
    /// the other.
    fn pump(
        &self,
        session: &SshSession,
        recorder: &Recorder,
        plan: &Plan,
        within: Duration,
    ) -> Result<String, String> {
        let deadline = Instant::now() + within;
        loop {
            for challenge in recorder.take_unserved() {
                plan(&challenge, session);
            }
            if recorder.connected.load(Ordering::SeqCst) {
                // Give the greeting a moment to arrive.
                let until = Instant::now() + Duration::from_secs(3);
                while Instant::now() < until {
                    let seen = String::from_utf8_lossy(&recorder.data.lock().unwrap()).to_string();
                    if seen.contains(GREETING) {
                        session.disconnect();
                        return Ok(seen);
                    }
                    std::thread::sleep(Duration::from_millis(30));
                }
                session.disconnect();
                return Ok(String::new());
            }
            if let Some(reason) = recorder.closed.lock().unwrap().clone() {
                return Err(reason);
            }
            if Instant::now() >= deadline {
                session.disconnect();
                return Err("timed out".to_string());
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // Nothing here may outlive the test; the runtime owns the listener.
        let runtime = std::mem::replace(
            &mut self.handle,
            tokio::runtime::Builder::new_current_thread()
                .build()
                .unwrap(),
        );
        runtime.shutdown_timeout(Duration::from_millis(500));
    }
}

/// A throwaway ed25519 key, made by ssh-keygen, in its armoured text form.
fn generate_key_pem() -> String {
    let dir = std::env::temp_dir().join(format!(
        "tako-testkey-{}-{:?}-{:?}",
        std::process::id(),
        std::thread::current().id(),
        Instant::now()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).expect("temp dir");
    let path = dir.join("host");

    let status = std::process::Command::new("ssh-keygen")
        .args(["-q", "-t", "ed25519", "-N", ""])
        .arg("-f")
        .arg(&path)
        // Closed, not inherited: ssh-keygen prompts before overwriting and an
        // inherited stdin turns that into a test that hangs with no output.
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .expect("run ssh-keygen");
    assert!(status.success(), "ssh-keygen failed");

    let pem = std::fs::read_to_string(&path).expect("read key");
    let _ = std::fs::remove_dir_all(&dir);
    pem
}

/// The same, decoded, for the server to serve as its host key.
fn generate_key() -> russh::keys::PrivateKey {
    russh::keys::decode_secret_key(&generate_key_pem(), None).expect("decode key")
}

fn password(text: &str) -> SshAuth {
    SshAuth::Password {
        password: text.to_string(),
    }
}

// ── Password ─────────────────────────────────────────────────────────────────

/// The path the app's form offers and nothing had ever exercised.
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
