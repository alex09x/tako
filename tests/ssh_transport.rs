// The SSH transport, without a server.
//
// A phone has no fork/exec, so this is the only way its terminal reaches a
// shell -- which makes the failure paths matter more than the happy one.
// A connection that hangs, or that sends a password to a host nobody
// checked, is worse than one that refuses.
//
// The happy path needs a real server and lives in `examples/ssh_smoke.rs`;
// what is here is everything provable without one.

#![cfg(feature = "ssh")]

use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tako_core::ssh::{SshAuth, SshConfig, SshEvents, SshPrompt, SshSession};

/// Records what the transport reports, so a test can assert on the sequence
/// rather than on timing.
#[derive(Default)]
struct Recorder {
    host_keys: Mutex<Vec<(String, String)>>,
    accept_host_key: AtomicBool,
    connected: AtomicBool,
    data: Mutex<Vec<u8>>,
    closed: Mutex<Option<String>>,
    close_count: AtomicUsize,
}

impl Recorder {
    fn accepting() -> Arc<Self> {
        let r = Arc::new(Self::default());
        r.accept_host_key.store(true, Ordering::SeqCst);
        r
    }

    fn refusing() -> Arc<Self> {
        Arc::new(Self::default())
    }

    /// Waits for the connection to end, or gives up.
    fn wait_closed(&self, within: Duration) -> Option<String> {
        let deadline = Instant::now() + within;
        while Instant::now() < deadline {
            if let Some(reason) = self.closed.lock().unwrap().clone() {
                return Some(reason);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        None
    }
}

/// UniFFI hands the transport a box, so the shared record sits behind an Arc.
struct Events(Arc<Recorder>);

impl SshEvents for Events {
    fn on_host_key(&self, algorithm: String, fingerprint: String) -> bool {
        self.0.host_keys.lock().unwrap().push((algorithm, fingerprint));
        self.0.accept_host_key.load(Ordering::SeqCst)
    }

    /// None of these tests reach a server that asks anything -- the
    /// challenge/response flow has its own file, against a server that does.
    fn on_keyboard_interactive(
        &self,
        _challenge_id: u64,
        _name: String,
        _instructions: String,
        _prompts: Vec<SshPrompt>,
    ) {
        unreachable!("no server here asks a question");
    }

    fn on_connected(&self) {
        self.0.connected.store(true, Ordering::SeqCst);
    }

    fn on_data(&self, data: Vec<u8>) {
        self.0.data.lock().unwrap().extend_from_slice(&data);
    }

    fn on_closed(&self, reason: String) {
        *self.0.closed.lock().unwrap() = Some(reason);
        self.0.close_count.fetch_add(1, Ordering::SeqCst);
    }
}

fn config(host: &str, port: u16, auth: SshAuth) -> SshConfig {
    SshConfig {
        host: host.to_string(),
        port,
        username: "nobody".to_string(),
        auth,
        term: "xterm-256color".to_string(),
        cols: 80,
        rows: 24,
    }
}

fn password() -> SshAuth {
    SshAuth::Password { password: "unused".to_string() }
}

/// A port nothing is listening on, so `connect` has something to fail
/// against without depending on the network.
fn dead_port() -> u16 {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind");
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    port
}

// ── Failing to connect ───────────────────────────────────────────────────────

#[test]
fn a_refused_connection_is_reported_not_swallowed() {
    let rec = Recorder::accepting();
    let _session = SshSession::connect(
        config("127.0.0.1", dead_port(), password()),
        Box::new(Events(rec.clone())),
    );

    let reason = rec.wait_closed(Duration::from_secs(10)).expect("never reported a close");
    assert!(!reason.is_empty(), "a failure has to say why");
    assert!(!rec.connected.load(Ordering::SeqCst));
}

#[test]
fn a_bad_private_key_fails_before_any_socket_work_matters() {
    let rec = Recorder::accepting();
    let _session = SshSession::connect(
        config(
            "127.0.0.1",
            dead_port(),
            SshAuth::PrivateKey {
                pem: "not a key at all".to_string(),
                passphrase: None,
            },
        ),
        Box::new(Events(rec.clone())),
    );

    let reason = rec.wait_closed(Duration::from_secs(10)).expect("never reported a close");
    assert!(!reason.is_empty());
}

#[test]
fn an_unresolvable_host_is_reported() {
    let rec = Recorder::accepting();
    let _session = SshSession::connect(
        config("no-such-host.invalid", 22, password()),
        Box::new(Events(rec.clone())),
    );

    let reason = rec.wait_closed(Duration::from_secs(15)).expect("never reported a close");
    assert!(!reason.is_empty());
}

// ── Lifecycle ────────────────────────────────────────────────────────────────

#[test]
fn connect_returns_immediately_rather_than_blocking_the_caller() {
    // On a phone the calling thread is the one drawing, so a connection that
    // blocks it is a frozen app for however long the network takes.
    let rec = Recorder::accepting();
    let started = Instant::now();
    let _session = SshSession::connect(
        config("192.0.2.1", 22, password()), // TEST-NET-1: routes nowhere
        Box::new(Events(rec.clone())),
    );

    assert!(
        started.elapsed() < Duration::from_millis(500),
        "connect blocked for {:?}",
        started.elapsed()
    );
}

#[test]
fn a_session_that_never_connected_reports_itself_disconnected() {
    let rec = Recorder::accepting();
    let session = SshSession::connect(
        config("127.0.0.1", dead_port(), password()),
        Box::new(Events(rec.clone())),
    );

    let _ = rec.wait_closed(Duration::from_secs(10));
    assert!(!session.is_connected());
}

#[test]
fn sending_to_a_dead_session_is_ignored_rather_than_fatal() {
    // A closed pty swallows writes; this does the same, because a host
    // cannot know the connection died between its keystroke and the send.
    let rec = Recorder::accepting();
    let session = SshSession::connect(
        config("127.0.0.1", dead_port(), password()),
        Box::new(Events(rec.clone())),
    );
    let _ = rec.wait_closed(Duration::from_secs(10));

    session.send(b"ls\n".to_vec());
    session.resize(100, 40);
    // Reaching here without a panic is the assertion.
}

#[test]
fn disconnecting_twice_is_harmless() {
    let rec = Recorder::accepting();
    let session = SshSession::connect(
        config("127.0.0.1", dead_port(), password()),
        Box::new(Events(rec.clone())),
    );

    session.disconnect();
    session.disconnect();
    assert!(!session.is_connected());
}

#[test]
fn a_connection_reports_its_close_exactly_once() {
    let rec = Recorder::accepting();
    let session = SshSession::connect(
        config("127.0.0.1", dead_port(), password()),
        Box::new(Events(rec.clone())),
    );

    let _ = rec.wait_closed(Duration::from_secs(10));
    session.disconnect();
    std::thread::sleep(Duration::from_millis(300));

    assert_eq!(rec.close_count.load(Ordering::SeqCst), 1);
}

// ── Host keys ────────────────────────────────────────────────────────────────

/// The decision the whole security story rests on. A client that sends
/// credentials to whatever answered the port has no security story, so the
/// host key is offered to the caller *before* authentication and a refusal
/// ends the connection there.
#[test]
fn refusing_the_host_key_stops_the_connection() {
    // Needs something that completes a key exchange, so it runs against a
    // real sshd when one is reachable and says so when it is not.
    let Some(port) = local_sshd_port() else {
        eprintln!("skipped: no sshd on 127.0.0.1:22");
        return;
    };

    let rec = Recorder::refusing();
    let _session = SshSession::connect(
        config("127.0.0.1", port, password()),
        Box::new(Events(rec.clone())),
    );

    let reason = rec.wait_closed(Duration::from_secs(15)).expect("never reported a close");
    assert!(!rec.host_keys.lock().unwrap().is_empty(), "the key was never offered");
    assert!(!rec.connected.load(Ordering::SeqCst), "connected despite a refused key");
    assert!(!reason.is_empty());
}

#[test]
fn the_host_key_is_offered_as_a_comparable_fingerprint() {
    let Some(port) = local_sshd_port() else {
        eprintln!("skipped: no sshd on 127.0.0.1:22");
        return;
    };

    let rec = Recorder::refusing();
    let _session = SshSession::connect(
        config("127.0.0.1", port, password()),
        Box::new(Events(rec.clone())),
    );
    let _ = rec.wait_closed(Duration::from_secs(15));

    let keys = rec.host_keys.lock().unwrap().clone();
    let (algorithm, fingerprint) = keys.first().expect("no host key was offered");
    // `SHA256:...` is the form `ssh-keygen -lf` prints, which is the only
    // form a user can actually check a fingerprint against.
    assert!(
        fingerprint.starts_with("SHA256:"),
        "fingerprint is not comparable: {fingerprint}"
    );
    assert!(!algorithm.is_empty());
}

/// The fingerprint is only useful if it is the *same* string the user can
/// get from the server, so this compares ours against `ssh-keygen -lf` for
/// the very key the server offered. A fingerprint that merely looks right is
/// a fingerprint nobody can check.
#[test]
fn the_fingerprint_matches_what_ssh_keygen_prints_for_that_key() {
    let Some(port) = local_sshd_port() else {
        eprintln!("skipped: no sshd on 127.0.0.1:22");
        return;
    };

    let rec = Recorder::refusing();
    let _session = SshSession::connect(
        config("127.0.0.1", port, password()),
        Box::new(Events(rec.clone())),
    );
    let _ = rec.wait_closed(Duration::from_secs(15));

    let keys = rec.host_keys.lock().unwrap().clone();
    let (algorithm, fingerprint) = keys.first().expect("no host key was offered").clone();

    // ssh-ed25519 -> /etc/ssh/ssh_host_ed25519_key.pub, and so on.
    let stem = match algorithm.as_str() {
        "ssh-ed25519" => "ed25519",
        "ssh-rsa" | "rsa-sha2-256" | "rsa-sha2-512" => "rsa",
        a if a.starts_with("ecdsa-sha2-") => "ecdsa",
        other => {
            eprintln!("skipped: no known host-key file for {other}");
            return;
        }
    };
    let path = format!("/etc/ssh/ssh_host_{stem}_key.pub");
    let Ok(output) = std::process::Command::new("ssh-keygen").args(["-lf", &path]).output() else {
        eprintln!("skipped: ssh-keygen is not available");
        return;
    };
    if !output.status.success() {
        eprintln!("skipped: could not read {path}");
        return;
    }

    let printed = String::from_utf8_lossy(&output.stdout);
    let expected = printed
        .split_whitespace()
        .find(|f| f.starts_with("SHA256:"))
        .expect("ssh-keygen printed no fingerprint");

    assert_eq!(fingerprint, expected, "host key {algorithm} from {path}");
}

/// True when something is listening on the local ssh port, so the two tests
/// that need a key exchange can skip cleanly on a machine without one.
fn local_sshd_port() -> Option<u16> {
    std::net::TcpStream::connect_timeout(
        &"127.0.0.1:22".parse().unwrap(),
        Duration::from_millis(300),
    )
    .ok()
    .map(|_| 22)
}
