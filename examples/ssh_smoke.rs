//! Connects over SSH, drives the shell, and prints the screen the engine drew.
//!
//! The whole mobile path in one process: bytes off a socket into the same
//! `Terminal` a phone would use, and the resulting screen read back with
//! `dump_text`. If this prints a prompt, a phone can too.
//!
//!     cargo run --example ssh_smoke --features ssh,pty -- \
//!         --host 192.0.2.1 --user user --key ~/.ssh/id_ed25519 \
//!         --command "echo hello from the far end"

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use tako_core::ssh::{SshAuth, SshConfig, SshEvents, SshPrompt, SshSession};
use tako_core::terminal::Terminal;

/// Feeds everything the far end says straight into a real terminal.
struct Screen {
    terminal: Mutex<Terminal>,
    connected: AtomicBool,
    closed: Mutex<Option<String>>,
    bytes: AtomicBool,
}

impl SshEvents for Screen {
    fn on_host_key(&self, algorithm: String, fingerprint: String) -> bool {
        println!("host key: {algorithm} {fingerprint}");
        // A real client asks the user once and remembers. Accepting here is
        // what makes this a smoke test rather than a client.
        true
    }

    fn on_connected(&self) {
        println!("connected");
        self.connected.store(true, Ordering::SeqCst);
    }

    fn on_keyboard_interactive(
        &self,
        _challenge_id: u64,
        name: String,
        instructions: String,
        prompts: Vec<SshPrompt>,
    ) {
        eprintln!(
            "server requested keyboard-interactive authentication ({name}: {instructions}; {} prompts); this non-interactive smoke example cannot answer it",
            prompts.len()
        );
    }

    fn on_data(&self, data: Vec<u8>) {
        self.bytes.store(true, Ordering::SeqCst);
        let mut term = self.terminal.lock().unwrap();
        term.feed(&data);
        let _ = term.take_output();
    }

    fn on_closed(&self, reason: String) {
        *self.closed.lock().unwrap() = Some(reason);
    }
}

fn arg(name: &str) -> Option<String> {
    let args: Vec<String> = std::env::args().collect();
    args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned()
}

fn main() {
    let host = arg("--host").unwrap_or_else(|| "127.0.0.1".to_string());
    let port: u16 = arg("--port").and_then(|p| p.parse().ok()).unwrap_or(22);
    let user = arg("--user").unwrap_or_else(whoami);
    let command = arg("--command");

    let auth = if let Some(path) = arg("--key") {
        let path = shellexpand(&path);
        let pem = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("could not read {path}: {e}"));
        SshAuth::PrivateKey { pem, passphrase: arg("--passphrase") }
    } else if let Some(password) = arg("--password") {
        SshAuth::Password { password }
    } else {
        eprintln!("need --key PATH or --password SECRET");
        std::process::exit(2);
    };

    let (cols, rows) = (80u32, 24u32);
    let screen = Arc::new(Screen {
        terminal: Mutex::new(Terminal::new(cols as usize, rows as usize)),
        connected: AtomicBool::new(false),
        closed: Mutex::new(None),
        bytes: AtomicBool::new(false),
    });

    let session = SshSession::connect(
        SshConfig {
            host: host.clone(),
            port,
            username: user.clone(),
            auth,
            term: "xterm-256color".to_string(),
            cols,
            rows,
        },
        Box::new(Handle(screen.clone())),
    );

    // Wait for the shell, or for a failure to explain itself.
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if screen.connected.load(Ordering::SeqCst) {
            break;
        }
        if let Some(reason) = screen.closed.lock().unwrap().clone() {
            eprintln!("failed: {reason}");
            std::process::exit(1);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    if !screen.connected.load(Ordering::SeqCst) {
        eprintln!("timed out waiting for a shell");
        std::process::exit(1);
    }

    if let Some(command) = command {
        session.send(format!("{command}\n").into_bytes());
    }

    // Let the far end answer, then look at what the engine drew.
    std::thread::sleep(Duration::from_secs(3));
    session.resize(100, 30);
    std::thread::sleep(Duration::from_millis(300));
    session.disconnect();
    std::thread::sleep(Duration::from_millis(300));

    println!("--- screen as the engine drew it ---");
    println!("{}", screen.terminal.lock().unwrap().dump_text());
    println!("--- end ---");

    if !screen.bytes.load(Ordering::SeqCst) {
        eprintln!("connected but the far end never said anything");
        std::process::exit(1);
    }
}

/// UniFFI's callback interface wants a plain box, so the shared state is
/// reached through an Arc behind it.
struct Handle(Arc<Screen>);

impl SshEvents for Handle {
    fn on_host_key(&self, algorithm: String, fingerprint: String) -> bool {
        self.0.on_host_key(algorithm, fingerprint)
    }
    fn on_connected(&self) {
        self.0.on_connected();
    }
    fn on_keyboard_interactive(
        &self,
        challenge_id: u64,
        name: String,
        instructions: String,
        prompts: Vec<SshPrompt>,
    ) {
        self.0
            .on_keyboard_interactive(challenge_id, name, instructions, prompts);
    }
    fn on_data(&self, data: Vec<u8>) {
        self.0.on_data(data);
    }
    fn on_closed(&self, reason: String) {
        self.0.on_closed(reason);
    }
}

fn whoami() -> String {
    std::env::var("USER").unwrap_or_else(|_| "root".to_string())
}

fn shellexpand(path: &str) -> String {
    if let Some(rest) = path.strip_prefix("~/")
        && let Ok(home) = std::env::var("HOME")
    {
        return format!("{home}/{rest}");
    }
    path.to_string()
}
