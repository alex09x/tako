/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

pub use std::io::Write;
pub use std::net::TcpStream;
pub use std::path::{Path, PathBuf};
pub use std::process::{Child, Command, Stdio};
pub use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
pub use std::sync::{Arc, Mutex, OnceLock};
pub use std::time::{Duration, Instant};

pub use tako_core::ssh::{SshAuth, SshConfig, SshEvents, SshPrompt, SshSession};

pub const SSHD: &str = "/usr/sbin/sshd";

/// A throwaway sshd: its own keys, its own port, gone when dropped.
pub struct TestServer {
    pub dir: PathBuf,
    pub port: u16,
    pub child: Child,
    pub client_key: String,
}

impl TestServer {
    /// Starts a server. `host_key_type` is an `ssh-keygen -t` name;
    /// `extra_config` lets a test pin ciphers, MACs or kex algorithms.
    pub fn start(host_key_type: &str, client_key_type: &str, extra_config: &str) -> Option<Self> {
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
    pub fn start_with_encrypted_client_key(passphrase: &str) -> Option<Self> {
        let mut server = Self::start("ed25519", "ed25519", "")?;
        // Replace the plain client key with an encrypted one of the same
        // public half, so authorized_keys still matches.
        let path = server.dir.join("client");
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_file(server.dir.join("client.pub"));
        keygen_full("ed25519", &path, passphrase, None)?;
        std::fs::copy(
            server.dir.join("client.pub"),
            server.dir.join("authorized_keys"),
        )
        .ok()?;
        server.client_key = std::fs::read_to_string(&path).ok()?;
        Some(server)
    }

    pub fn shell_says(&self, command: &str) -> Result<String, String> {
        self.shell_says_with_passphrase(command, None)
    }

    /// Connects, waits for a shell, and returns what the far end said.
    pub fn shell_says_with_passphrase(
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

pub fn sshd_start_lock() -> &'static Mutex<()> {
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
pub struct Recorder {
    pub connected: AtomicBool,
    pub data: Mutex<Vec<u8>>,
    pub closed: Mutex<Option<String>>,
}

pub struct Events(Arc<Recorder>);

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

pub fn keygen(kind: &str, path: &Path) -> Option<()> {
    keygen_full(kind, path, "", None)
}

/// `kind` may carry a size, as `ecdsa:521` or `rsa:4096`, because the curve
/// and the modulus are the thing being varied.
pub fn keygen_full(kind: &str, path: &Path, passphrase: &str, bits: Option<&str>) -> Option<()> {
    let (kind, inline_bits) = match kind.split_once(':') {
        Some((k, b)) => (k, Some(b.to_string())),
        None => (kind, None),
    };
    let bits = bits.map(str::to_string).or(inline_bits);

    let mut cmd = Command::new("ssh-keygen");
    cmd.args(["-q", "-t", kind, "-N", passphrase, "-f"])
        .arg(path);
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
pub struct MachineLock(std::fs::File);

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

pub fn port_in_use(port: u16) -> bool {
    std::net::TcpListener::bind(("127.0.0.1", port)).is_err()
}

pub fn free_port() -> Option<u16> {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").ok()?;
    let port = listener.local_addr().ok()?.port();
    drop(listener);
    Some(port)
}

pub fn unique_suffix() -> u64 {
    // Clock-derived names can collide when parallel tests read a coarse host
    // clock in the same tick. One test would then remove another test's keys
    // before sshd opened them, producing connection resets and false skips.
    static NEXT: AtomicU64 = AtomicU64::new(0);
    NEXT.fetch_add(1, Ordering::Relaxed)
}

pub fn whoami() -> String {
    std::env::var("USER").unwrap_or_else(|_| "root".to_string())
}

/// Runs `body` against a server, or prints why it did not and returns.
pub fn with_server(host_key: &str, client_key: &str, extra: &str, body: impl FnOnce(&TestServer)) {
    if !Path::new(SSHD).exists() {
        eprintln!("skipped: {SSHD} is unavailable");
        return;
    }
    let server = TestServer::start(host_key, client_key, extra).unwrap_or_else(|| {
        panic!("installed sshd failed to start for {host_key}/{client_key} [{extra}]")
    });
    body(&server);
}

pub fn require_server(server: Option<TestServer>, context: &str) -> Option<TestServer> {
    if !Path::new(SSHD).exists() {
        eprintln!("skipped: {SSHD} is unavailable");
        return None;
    }
    Some(server.unwrap_or_else(|| panic!("installed sshd failed to start: {context}")))
}

/// The marker proves the shell really ran the command rather than merely
/// echoing it back as terminal echo.
pub const PROBE: &str = "printf 'TAKO_%s\\n' MARKER";
