//! A terminal with no window: runs a real program against the real engine.
//!
//! Everything above the parser — the app, the GPU renderer, AppKit — is left
//! out. What remains is the loop that actually defines a terminal to the
//! program inside it: read the pty, feed the engine, write its replies back.
//!
//! That is exactly the contract conformance suites test against. esctest
//! writes escape sequences to its stdout and reads the terminal's answers
//! from its stdin; it neither knows nor cares whether anything was drawn. So
//! this runs it — and vttest, and anything else — without a display, a
//! window server, or a human.
//!
//!     cargo run --example headless -- [--rows N] [--cols N]
//!                                     [--dump FILE] [--quiet] -- PROGRAM ARGS...
//!
//! On exit the child's status is this process's status, so a test runner can
//! read it directly. With `--dump` the final screen is written as a snapshot
//! in the same format as `Terminal::dump()`.

use std::io::{Read, Write};
use std::process::ExitCode;

use tako_core::pty::Pty;
use tako_core::terminal::Terminal;

struct Options {
    rows: u16,
    cols: u16,
    dump: Option<String>,
    quiet: bool,
    no_stdin: bool,
    /// Escape sequences fed to the terminal before the child starts.
    ///
    /// esctest reads the screen back with DECRQCRA, and which of xterm's
    /// several checksum conventions it assumes is a command-line flag on its
    /// side and an XTCHECKSUM sequence on ours -- which esctest never sends.
    /// Without a way to select one here, the suite measures the difference
    /// between two conventions rather than anything about the terminal.
    init: Option<String>,
    argv: Vec<String>,
}

fn usage() -> ! {
    eprintln!(
        "usage: headless [--rows N] [--cols N] [--dump FILE] [--quiet] [--no-stdin] \
                [--init ESCAPES] -- PROGRAM [ARGS...]"
    );
    std::process::exit(2);
}

fn parse_args() -> Options {
    let mut opts = Options {
        rows: 24,
        cols: 80,
        dump: None,
        quiet: false,
        no_stdin: false,
        init: None,
        argv: Vec::new(),
    };

    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--rows" => opts.rows = args.next().and_then(|v| v.parse().ok()).unwrap_or_else(|| usage()),
            "--cols" => opts.cols = args.next().and_then(|v| v.parse().ok()).unwrap_or_else(|| usage()),
            "--dump" => opts.dump = Some(args.next().unwrap_or_else(|| usage())),
            "--quiet" => opts.quiet = true,
            "--no-stdin" => opts.no_stdin = true,
            // `\e` for escape, so the sequence survives a shell argument.
            "--init" => {
                opts.init = Some(
                    args.next()
                        .unwrap_or_else(|| usage())
                        .replace("\\e", "\x1b"),
                )
            }
            "--" => {
                opts.argv = args.collect();
                break;
            }
            other => {
                // Allow the separator to be omitted when the program name
                // cannot be mistaken for an option.
                if other.starts_with("--") {
                    usage();
                }
                opts.argv.push(other.to_string());
                opts.argv.extend(args);
                break;
            }
        }
    }

    if opts.argv.is_empty() {
        usage();
    }
    opts
}

fn main() -> ExitCode {
    let opts = parse_args();

    let argv: Vec<&str> = opts.argv.iter().map(String::as_str).collect();
    let pty = Pty::spawn_command(&argv, &[], opts.rows, opts.cols);
    let mut term = Terminal::new(opts.cols as usize, opts.rows as usize);
    if let Some(init) = &opts.init {
        term.feed(init.as_bytes());
        // Anything the init sequence asked the terminal to say goes nowhere:
        // the child is not running yet, and a stray reply would arrive as
        // input to whatever starts next.
        let _ = term.take_output();
    }

    // Forward our own stdin to the child, so a session can be driven from a
    // script: type a command, wait, send ^C, and read back what the screen
    // ended up saying. Without this the host can only watch a program that
    // needs no input. A pipe that ends leaves the child running, because a
    // driving script is usually shorter than the session it drives.
    if !opts.no_stdin {
        let mut sink = pty.master.try_clone().expect("clone pty master");
        std::thread::spawn(move || {
            let mut stdin = std::io::stdin();
            let mut buf = [0u8; 4096];
            while let Ok(n) = stdin.read(&mut buf) {
                if n == 0 || sink.write_all(&buf[..n]).is_err() {
                    break;
                }
                let _ = sink.flush();
            }
        });
    }

    let mut master = &pty.master;
    let mut buf = [0u8; 8192];

    loop {
        let n = match master.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            // The child closing its side surfaces as EIO on the master.
            Err(e) if e.raw_os_error() == Some(libc::EIO) => break,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(e) => {
                eprintln!("headless: read failed: {e}");
                break;
            }
        };

        term.feed(&buf[..n]);

        // Device replies are the whole point: a suite that asks where the
        // cursor is, or for a checksum, is blocked until this lands.
        let reply = term.take_output();
        if !reply.is_empty() {
            let mut writer = &pty.master;
            if let Err(e) = writer.write_all(&reply) {
                eprintln!("headless: reply failed: {e}");
                break;
            }
            let _ = writer.flush();
        }

        if !opts.quiet {
            // Pass the program's own output through, so a human watching a
            // long suite can see it working.
            let _ = std::io::stdout().write_all(&buf[..n]);
            let _ = std::io::stdout().flush();
        }
    }

    let status = pty.wait();

    if let Some(path) = opts.dump
        && let Err(e) = std::fs::write(&path, term.dump())
    {
        eprintln!("headless: could not write {path}: {e}");
        return ExitCode::from(1);
    }

    ExitCode::from(u8::try_from(status).unwrap_or(1))
}
