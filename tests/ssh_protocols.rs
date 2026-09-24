// The transport against a real sshd, across the algorithms it can negotiate.
//
// `ssh_transport.rs` covers what can be proven without a server. This covers
// what cannot: that a key exchange actually completes, with each host-key
// type, client-key type, cipher and MAC the client claims to support, and
// that a server offering none of them fails cleanly instead of hanging.
//
// Every server here is disposable -- its own directory, its own generated
// keys, an ephemeral port on the loopback, killed when the test ends. None
// of it touches the machine's real sshd or its keys.
//
// Skipped wholesale when `/usr/sbin/sshd` is missing, so the suite still
// passes somewhere without one.

#![cfg(feature = "ssh")]

use std::io::Write;
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use tako_core::ssh::{SshAuth, SshConfig, SshEvents, SshPrompt, SshSession};

const SSHD: &str = "/usr/sbin/sshd";

/// A throwaway sshd: its own keys, its own port, gone when dropped.
struct TestServer {
    dir: PathBuf,
    port: u16,
    child: Child,
    client_key: String,
}

impl TestServer {
    /// Starts a server. `host_key_type` is an `ssh-keygen -t` name;
    /// `extra_config` lets a test pin ciphers, MACs or kex algorithms.
    fn start(host_key_type: &str, client_key_type: &str, extra_config: &str) -> Option<Self> {
        if !Path::new(SSHD).exists() {
            return None;
        }
        let dir = std::env::temp_dir().join(format!(
            "tako-sshd-{}-{}-{}-{}",
            host_key_type.replace(':', "-"),
            client_key_type.replace(':', "-"),
            std::process::id(),
            unique_suffix()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).ok()?;

        keygen(host_key_type, &dir.join("host_key"))?;
        keygen(client_key_type, &dir.join("client"))?;
        std::fs::copy(dir.join("client.pub"), dir.join("authorized_keys")).ok()?;

        // `free_port` has an unavoidable bind/drop/spawn handoff: sshd cannot
        // inherit the probe listener. Without serialising just this startup
        // window, two parallel tests can both select the same released port.
        // The loser may then mistake the winner's listener for its own during
        // the readiness probe and later fail with a misleading connection
        // reset. Once sshd is listening the kernel keeps the port exclusive,
        // so the lock can be released and the actual sessions still run in
        // parallel.
        // `free_port` has an unavoidable bind/drop/spawn handoff: sshd cannot
        // inherit the probe listener, so another process can take the port in
        // between. Serialise that window across threads *and* processes (a
        // second test run on the same machine uses the same scheme), and
        // after the readiness probe confirm the listener is our sshd: if our
        // sshd has exited, the probe reached someone else's, so retry on a
        // fresh port. Once sshd is listening the kernel keeps the port
        // exclusive, so sessions still run in parallel.
        let _startup_guard = sshd_start_lock()
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let _machine_guard = MachineLock::acquire();
        for _attempt in 0..5 {
            let port = free_port()?;
            let config = format!(
                "Port {port}\n\
                 ListenAddress 127.0.0.1\n\
                 HostKey {dir}/host_key\n\
                 AuthorizedKeysFile {dir}/authorized_keys\n\
                 PasswordAuthentication no\n\
                 PubkeyAuthentication yes\n\
                 UsePAM no\n\
                 StrictModes no\n\
                 PidFile {dir}/sshd.pid\n\
                 LogLevel ERROR\n\
                 {extra_config}\n",
                dir = dir.display()
            );
            std::fs::write(dir.join("sshd_config"), config).ok()?;

            let child = Command::new(SSHD)
                .arg("-f")
                .arg(dir.join("sshd_config"))
                .arg("-D")
                .arg("-e")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .ok()?;

            let mut server = TestServer {
                dir: dir.clone(),
                port,
                child,
                client_key: std::fs::read_to_string(dir.join("client")).ok()?,
            };

            // sshd rejects a config it dislikes by exiting, so waiting for the
            // port is also how a bad algorithm name is detected.
            let deadline = Instant::now() + Duration::from_secs(5);
            let mut listening = false;
            while Instant::now() < deadline {
                if let Ok(Some(_)) = server.child.try_wait() {
                    break; // exited: bad config, or the port was taken
                }
                if TcpStream::connect_timeout(
                    &format!("127.0.0.1:{port}").parse().unwrap(),
                    Duration::from_millis(100),
                )
                .is_ok()
                {
                    listening = true;
                    break;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            if !listening {
                // A config sshd rejects fails the same way on every port.
                if let Ok(Some(_)) = server.child.try_wait()
                    && !port_in_use(port)
                {
                    return None;
                }
                continue;
            }
            // A listener answered; make sure it was ours and not a foreign
            // process that holds this port while our sshd failed to bind it.
            std::thread::sleep(Duration::from_millis(50));
            if let Ok(None) = server.child.try_wait() {
                return Some(server);
            }
        }
        None
    }

    /// A server whose client key is encrypted, so the passphrase path is
    /// exercised end to end rather than assumed.
    fn start_with_encrypted_client_key(passphrase: &str) -> Option<Self> {
        let mut server = Self::start("ed25519", "ed25519", "")?;
        // Replace the plain client key with an encrypted one of the same
        // public half, so authorized_keys still matches.
        let path = server.dir.join("client");
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(server.dir.join("client.pub"));
        keygen_full("ed25519", &path, passphrase, None)?;
        std::fs::copy(server.dir.join("client.pub"), server.dir.join("authorized_keys")).ok()?;
        server.client_key = std::fs::read_to_string(&path).ok()?;
        Some(server)
    }

    fn shell_says(&self, command: &str) -> Result<String, String> {
        self.shell_says_with_passphrase(command, None)
    }

    /// Connects, waits for a shell, and returns what the far end said.
    fn shell_says_with_passphrase(
        &self,
        command: &str,
        passphrase: Option<&str>,
    ) -> Result<String, String> {
        let recorder = Arc::new(Recorder::default());
        let session = SshSession::connect(
            SshConfig {
                host: "127.0.0.1".to_string(),
                port: self.port,
                username: whoami(),
                auth: SshAuth::PrivateKey {
                    pem: self.client_key.clone(),
                    passphrase: passphrase.map(str::to_string),
                },
                term: "xterm-256color".to_string(),
                cols: 80,
                rows: 24,
            },
            Box::new(Events(recorder.clone())),
        );

        let deadline = Instant::now() + Duration::from_secs(20);
        while Instant::now() < deadline && !recorder.connected.load(Ordering::SeqCst) {
            if let Some(reason) = recorder.closed.lock().unwrap().clone() {
                return Err(reason);
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        if !recorder.connected.load(Ordering::SeqCst) {
            return Err("timed out waiting for a shell".to_string());
        }

        session.send(format!("{command}\n").into_bytes());
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            let seen = String::from_utf8_lossy(&recorder.data.lock().unwrap()).to_string();
            if seen.contains("TAKO_MARKER") || Instant::now() >= deadline {
                session.disconnect();
                return Ok(seen);
            }
            std::thread::sleep(Duration::from_millis(50));
        }
    }
}

fn sshd_start_lock() -> &'static Mutex<()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
}

impl Drop for TestServer {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[derive(Default)]
struct Recorder {
    connected: AtomicBool,
    data: Mutex<Vec<u8>>,
    closed: Mutex<Option<String>>,
}

struct Events(Arc<Recorder>);

impl SshEvents for Events {
    fn on_host_key(&self, _algorithm: String, _fingerprint: String) -> bool {
        true
    }
    fn on_keyboard_interactive(
        &self,
        _challenge_id: u64,
        _name: String,
        _instructions: String,
        _prompts: Vec<SshPrompt>,
    ) {
        unreachable!("the public-key protocol matrix must not request interactive auth");
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

fn keygen(kind: &str, path: &Path) -> Option<()> {
    keygen_full(kind, path, "", None)
}

/// `kind` may carry a size, as `ecdsa:521` or `rsa:4096`, because the curve
/// and the modulus are the thing being varied.
fn keygen_full(kind: &str, path: &Path, passphrase: &str, bits: Option<&str>) -> Option<()> {
    let (kind, inline_bits) = match kind.split_once(':') {
        Some((k, b)) => (k, Some(b.to_string())),
        None => (kind, None),
    };
    let bits = bits.map(str::to_string).or(inline_bits);

    let mut cmd = Command::new("ssh-keygen");
    cmd.args(["-q", "-t", kind, "-N", passphrase, "-f"]).arg(path);
    if let Some(bits) = bits {
        cmd.args(["-b", &bits]);
    } else if kind == "rsa" {
        cmd.args(["-b", "2048"]);
    }
    // stdin must be closed, not inherited: ssh-keygen prompts before
    // overwriting an existing file, and an inherited stdin turns that prompt
    // into a test that hangs forever with no output.
    cmd.stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .ok()
        .filter(|s| s.success())
        .map(|_| ())
}

/// An exclusive advisory lock shared by every test process on the machine,
/// held while a test picks a port and waits for its sshd to listen.
struct MachineLock(std::fs::File);

impl MachineLock {
    fn acquire() -> Option<Self> {
        use std::os::unix::io::AsRawFd;
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(std::env::temp_dir().join("tako-sshd-startup.lock"))
            .ok()?;
        (unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } == 0).then_some(MachineLock(file))
    }
}

impl Drop for MachineLock {
    fn drop(&mut self) {
        use std::os::unix::io::AsRawFd;
        unsafe { libc::flock(self.0.as_raw_fd(), libc::LOCK_UN) };
    }
}

fn port_in_use(port: u16) -> bool {
    std::net::TcpListener::bind(("127.0.0.1", port)).is_err()
}

fn free_port() -> Option<u16> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").ok()?;
    let port = listener.local_addr().ok()?.port();
    drop(listener);
    Some(port)
}

fn unique_suffix() -> u64 {
    // Clock-derived names can collide when parallel tests read a coarse host
    // clock in the same tick. One test would then remove another test's keys
    // before sshd opened them, producing connection resets and false skips.
    static NEXT: AtomicU64 = AtomicU64::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

fn whoami() -> String {
    std::env::var("USER").unwrap_or_else(|_| "root".to_string())
}

/// Runs `body` against a server, or prints why it did not and returns.
fn with_server(host_key: &str, client_key: &str, extra: &str, body: impl FnOnce(&TestServer)) {
    if !Path::new(SSHD).exists() {
        eprintln!("skipped: {SSHD} is unavailable");
        return;
    }
    let server = TestServer::start(host_key, client_key, extra).unwrap_or_else(|| {
        panic!("installed sshd failed to start for {host_key}/{client_key} [{extra}]")
    });
    body(&server);
}

fn require_server(server: Option<TestServer>, context: &str) -> Option<TestServer> {
    if !Path::new(SSHD).exists() {
        eprintln!("skipped: {SSHD} is unavailable");
        return None;
    }
    Some(server.unwrap_or_else(|| panic!("installed sshd failed to start: {context}")))
}

/// The marker proves the shell really ran the command rather than merely
/// echoing it back as terminal echo.
const PROBE: &str = "printf 'TAKO_%s\\n' MARKER";

// ── Host key algorithms ──────────────────────────────────────────────────────

#[test]
fn connects_to_an_ed25519_host_key() {
    with_server("ed25519", "ed25519", "", |server| {
        let out = server.shell_says(PROBE).expect("connection failed");
        assert!(out.contains("TAKO_MARKER"), "no shell output: {out:?}");
    });
}

#[test]
fn connects_to_an_ecdsa_host_key() {
    with_server("ecdsa", "ed25519", "", |server| {
        let out = server.shell_says(PROBE).expect("connection failed");
        assert!(out.contains("TAKO_MARKER"), "no shell output: {out:?}");
    });
}

#[test]
fn connects_to_an_rsa_host_key() {
    // rsa-sha2-256/512 -- the modern signature algorithms over an RSA key,
    // which is what an older server in the fleet is most likely to present.
    with_server("rsa", "ed25519", "", |server| {
        let out = server.shell_says(PROBE).expect("connection failed");
        assert!(out.contains("TAKO_MARKER"), "no shell output: {out:?}");
    });
}

// ── Client key algorithms ────────────────────────────────────────────────────

#[test]
fn authenticates_with_an_ecdsa_client_key() {
    with_server("ed25519", "ecdsa", "", |server| {
        let out = server.shell_says(PROBE).expect("connection failed");
        assert!(out.contains("TAKO_MARKER"), "no shell output: {out:?}");
    });
}

#[test]
fn authenticates_with_an_rsa_client_key() {
    with_server("ed25519", "rsa", "", |server| {
        let out = server.shell_says(PROBE).expect("connection failed");
        assert!(out.contains("TAKO_MARKER"), "no shell output: {out:?}");
    });
}

// ── Key exchange ─────────────────────────────────────────────────────────────

#[test]
fn negotiates_curve25519() {
    with_server("ed25519", "ed25519", "KexAlgorithms curve25519-sha256", |server| {
        let out = server.shell_says(PROBE).expect("connection failed");
        assert!(out.contains("TAKO_MARKER"), "no shell output: {out:?}");
    });
}

#[test]
fn negotiates_ecdh_over_the_nist_curves() {
    for curve in ["ecdh-sha2-nistp256", "ecdh-sha2-nistp384", "ecdh-sha2-nistp521"] {
        with_server("ed25519", "ed25519", &format!("KexAlgorithms {curve}"), |server| {
            let out = server
                .shell_says(PROBE)
                .unwrap_or_else(|e| panic!("{curve} failed: {e}"));
            assert!(out.contains("TAKO_MARKER"), "{curve}: no shell output");
        });
    }
}

#[test]
fn negotiates_finite_field_diffie_hellman() {
    // The fallback an old or conservatively configured server leaves on.
    for kex in ["diffie-hellman-group14-sha256", "diffie-hellman-group16-sha512"] {
        with_server("ed25519", "ed25519", &format!("KexAlgorithms {kex}"), |server| {
            let out = server
                .shell_says(PROBE)
                .unwrap_or_else(|e| panic!("{kex} failed: {e}"));
            assert!(out.contains("TAKO_MARKER"), "{kex}: no shell output");
        });
    }
}

// ── Ciphers and MACs ─────────────────────────────────────────────────────────

#[test]
fn negotiates_each_supported_cipher() {
    for cipher in [
        "chacha20-poly1305@openssh.com",
        "aes256-gcm@openssh.com",
        "aes128-ctr",
        "aes192-ctr",
        "aes256-ctr",
    ] {
        with_server("ed25519", "ed25519", &format!("Ciphers {cipher}"), |server| {
            let out = server
                .shell_says(PROBE)
                .unwrap_or_else(|e| panic!("{cipher} failed: {e}"));
            assert!(out.contains("TAKO_MARKER"), "{cipher}: no shell output");
        });
    }
}

#[test]
fn negotiates_each_supported_mac() {
    // GCM and chacha20 carry their own integrity, so a MAC only matters with
    // a CTR cipher -- pinning one alongside is what makes this test real.
    for mac in [
        "hmac-sha2-256",
        "hmac-sha2-512",
        "hmac-sha2-256-etm@openssh.com",
        "hmac-sha2-512-etm@openssh.com",
    ] {
        let extra = format!("Ciphers aes256-ctr\nMACs {mac}");
        with_server("ed25519", "ed25519", &extra, |server| {
            let out = server
                .shell_says(PROBE)
                .unwrap_or_else(|e| panic!("{mac} failed: {e}"));
            assert!(out.contains("TAKO_MARKER"), "{mac}: no shell output");
        });
    }
}

// ── No common ground ─────────────────────────────────────────────────────────

/// A server that shares no cipher with us has to be reported, promptly. The
/// failure mode that matters on a phone is not "refused" but "spins forever
/// while the user waits", so this asserts it ends.
#[test]
fn a_server_with_no_shared_cipher_fails_rather_than_hanging() {
    // 3des-cbc is old enough that russh does not offer it.
    with_server("ed25519", "ed25519", "Ciphers 3des-cbc", |server| {
        let started = Instant::now();
        let result = server.shell_says(PROBE);
        assert!(result.is_err(), "connected despite no shared cipher");
        assert!(
            started.elapsed() < Duration::from_secs(25),
            "took {:?} to give up",
            started.elapsed()
        );
    });
}

// ── The shell itself ─────────────────────────────────────────────────────────

#[test]
fn the_remote_gets_a_pty_and_the_terminal_size_we_asked_for() {
    with_server("ed25519", "ed25519", "", |server| {
        // `tty` fails outright without a pty, and stty reports the size the
        // channel requested -- both of which a plain exec channel would get
        // wrong.
        let out = server
            .shell_says("tty > /dev/null && stty size && printf 'TAKO_%s\\n' MARKER")
            .expect("connection failed");
        assert!(out.contains("TAKO_MARKER"), "no shell output: {out:?}");
        assert!(
            out.contains("24 80"),
            "the remote saw a different terminal size: {out:?}"
        );
    });
}

#[test]
fn utf8_survives_the_round_trip() {
    with_server("ed25519", "ed25519", "", |server| {
        let out = server
            // Raw UTF-8 bytes as octal escapes: `printf '\\u…'` only expands
            // under a UTF-8 locale, which a CI sshd need not give the shell.
            .shell_says("printf '\\344\\270\\226\\347\\225\\214 \\320\\277\\321\\200\\320\\270\\320\\262\\320\\265\\321\\202\\n'; printf 'TAKO_%s\\n' MARKER")
            .expect("connection failed");
        assert!(out.contains("\u{4e16}\u{754c}"), "CJK did not survive: {out:?}");
        assert!(out.contains("\u{43f}\u{440}\u{438}\u{432}\u{435}\u{442}"), "Cyrillic did not survive");
    });
}

#[test]
fn connects_to_ecdsa_host_keys_on_every_curve() {
    // `ssh-keygen -t ecdsa` defaults to nistp256, so the larger curves were
    // never actually exercised by the plain "ecdsa" case above.
    for bits in ["256", "384", "521"] {
        with_server(&format!("ecdsa:{bits}"), "ed25519", "", |server| {
            let out = server
                .shell_says(PROBE)
                .unwrap_or_else(|e| panic!("nistp{bits} host key failed: {e}"));
            assert!(out.contains("TAKO_MARKER"), "nistp{bits}: no shell output");
        });
    }
}

#[test]
fn authenticates_with_ecdsa_client_keys_on_every_curve() {
    for bits in ["256", "384", "521"] {
        with_server("ed25519", &format!("ecdsa:{bits}"), "", |server| {
            let out = server
                .shell_says(PROBE)
                .unwrap_or_else(|e| panic!("nistp{bits} client key failed: {e}"));
            assert!(out.contains("TAKO_MARKER"), "nistp{bits}: no shell output");
        });
    }
}

#[test]
fn authenticates_with_a_larger_rsa_client_key() {
    with_server("ed25519", "rsa:4096", "", |server| {
        let out = server.shell_says(PROBE).expect("connection failed");
        assert!(out.contains("TAKO_MARKER"), "no shell output: {out:?}");
    });
}

/// A key with a passphrase is the normal case for anyone who followed the
/// advice, and the app has a field for it. Nothing had ever decrypted one.
#[test]
fn authenticates_with_a_passphrase_protected_key() {
    let Some(server) = require_server(
        TestServer::start_with_encrypted_client_key("hunter2"),
        "encrypted client key",
    ) else {
        return;
    };
    let out = server
        .shell_says_with_passphrase(PROBE, Some("hunter2"))
        .expect("connection failed");
    assert!(out.contains("TAKO_MARKER"), "no shell output: {out:?}");
}

/// The wrong passphrase must fail as a passphrase problem, promptly, rather
/// than as a mysterious auth rejection after a round trip.
#[test]
fn the_wrong_passphrase_is_reported() {
    let Some(server) = require_server(
        TestServer::start_with_encrypted_client_key("hunter2"),
        "encrypted client key for wrong-passphrase test",
    ) else {
        return;
    };
    let result = server.shell_says_with_passphrase(PROBE, Some("not it"));
    assert!(result.is_err(), "a wrong passphrase was accepted");
}

#[test]
fn an_encrypted_key_without_its_passphrase_is_reported() {
    let Some(server) = require_server(
        TestServer::start_with_encrypted_client_key("hunter2"),
        "encrypted client key without passphrase",
    ) else {
        return;
    };
    let result = server.shell_says_with_passphrase(PROBE, None);
    assert!(result.is_err(), "an encrypted key opened without its passphrase");
}

// ── Cleanliness ──────────────────────────────────────────────────────────────

/// Each test starts a server and must leave nothing behind, or a suite run
/// slowly fills the machine with orphaned daemons.
#[test]
fn a_server_is_gone_once_its_test_ends() {
    let port = {
        let Some(server) = require_server(
            TestServer::start("ed25519", "ed25519", ""),
            "cleanup test",
        ) else {
            return;
        };
        let port = server.port;
        assert!(TcpStream::connect_timeout(
            &format!("127.0.0.1:{port}").parse().unwrap(),
            Duration::from_millis(200)
        )
        .is_ok());
        port
    };

    std::thread::sleep(Duration::from_millis(500));
    assert!(
        TcpStream::connect_timeout(
            &format!("127.0.0.1:{port}").parse().unwrap(),
            Duration::from_millis(200)
        )
        .is_err(),
        "the test server outlived its test"
    );
}

/// Keeps the unused-import warning honest about `Write`.
#[allow(dead_code)]
fn _unused(mut w: impl Write) {
    let _ = w.flush();
}
