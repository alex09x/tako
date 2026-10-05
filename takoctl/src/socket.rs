/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Finding the app's control socket and talking to it.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::{Duration, Instant};

use serde_json::Value;
use sha2::{Digest, Sha256};

/// How long to wait for the app to take the request and to answer.
pub const TIMEOUT: Duration = Duration::from_secs(30);

/// The socket of the app with `bundle_id`, named the way the app names it:
/// `tako-ctl-<12 hex of sha256(bundle id)>.sock` in this user's private
/// temporary directory.
pub fn default_path(bundle_id: &str) -> Result<String, String> {
    let dir = user_temp_dir()?;
    let digest = Sha256::digest(bundle_id.as_bytes());
    let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    Ok(format!("{}/tako-ctl-{}.sock", dir.trim_end_matches('/'), &hex[..12]))
}

#[cfg(target_os = "macos")]
fn user_temp_dir() -> Result<String, String> {
    let mut buf = vec![0u8; libc::PATH_MAX as usize];
    let n = unsafe { libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, buf.as_mut_ptr().cast(), buf.len()) };
    if n == 0 || n > buf.len() {
        return Err("no per-user temporary directory".into());
    }
    buf.truncate(n - 1);
    String::from_utf8(buf).map_err(|_| "temporary directory is not UTF-8".into())
}

#[cfg(not(target_os = "macos"))]
fn user_temp_dir() -> Result<String, String> {
    Err("Tako runs on macOS; pass --socket".into())
}

/// Largest answer read; a larger one is refused rather than held.
pub const MAX_ANSWER_BYTES: usize = 16 << 20;

/// Sends one request line and reads the one-line answer, all of it within
/// `TIMEOUT` -- connecting included.
#[allow(dead_code)]
pub fn exchange(path: &str, request: &Value) -> Result<Value, Failure> {
    exchange_within(path, request, TIMEOUT, MAX_ANSWER_BYTES)
}

/// Why no answer was read, and whether the request had already gone out --
/// which decides whether it may have been carried out.
#[derive(Debug)]
pub struct Failure {
    pub message: String,
    pub sent: bool,
}

impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl Failure {
    #[allow(dead_code)]
    pub fn contains(&self, s: &str) -> bool {
        self.message.contains(s)
    }
}

pub fn exchange_within(path: &str, request: &Value, limit: Duration, max: usize) -> Result<Value, Failure> {
    let unsent = |message: String| Failure { message, sent: false };
    let sent = |message: String| Failure { message, sent: true };
    let deadline = Instant::now() + limit;
    let mut stream = connect(path, deadline).map_err(unsent)?;
    let mut line = serde_json::to_vec(request).map_err(|e| unsent(e.to_string()))?;
    line.push(b'\n');
    let mut written = 0;
    while written < line.len() {
        stream.set_write_timeout(Some(left(deadline).map_err(unsent)?)).map_err(|e| unsent(e.to_string()))?;
        match stream.write(&line[written..]) {
            Ok(0) => return Err(unsent("the connection closed".into())),
            Ok(n) => written += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(unsent(timeout_or(e))),
        }
    }
    let mut answer = Vec::new();
    let mut chunk = [0u8; 64 * 1024];
    loop {
        stream.set_read_timeout(Some(left(deadline).map_err(sent)?)).map_err(|e| sent(e.to_string()))?;
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(n) => {
                let got = &chunk[..n];
                let line_end = got.iter().position(|&b| b == b'\n');
                let take = line_end.unwrap_or(n);
                // The cap holds for the whole line, newline or not.
                if answer.len() + take > max {
                    return Err(sent(format!("answer larger than {max} bytes")));
                }
                answer.extend_from_slice(&got[..take]);
                if line_end.is_some() {
                    break;
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(sent(timeout_or(e))),
        }
    }
    if answer.is_empty() {
        return Err(sent("the connection closed without an answer".into()));
    }
    serde_json::from_slice(&answer).map_err(|e| sent(format!("unreadable answer: {e}")))
}

/// Connects, sends the streaming request, and calls `on_line` for each received line.
pub fn stream_events<F>(path: &str, request: &Value, mut on_line: F) -> Result<(), Failure>
where
    F: FnMut(&str) -> Result<(), String>,
{
    let unsent = |message: String| Failure { message, sent: false };
    let sent = |message: String| Failure { message, sent: true };
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut stream = connect(path, deadline).map_err(unsent)?;
    let mut line = serde_json::to_vec(request).map_err(|e| unsent(e.to_string()))?;
    line.push(b'\n');
    stream.write_all(&line).map_err(|e| unsent(e.to_string()))?;

    use std::io::BufRead;
    let reader = std::io::BufReader::new(stream);
    for line_res in reader.lines() {
        let text = line_res.map_err(|e| sent(e.to_string()))?;
        if text.trim().is_empty() { continue; }
        on_line(&text).map_err(sent)?;
    }
    Ok(())
}


fn left(deadline: Instant) -> Result<Duration, String> {
    let now = Instant::now();
    if now >= deadline {
        return Err("timed out".into());
    }
    Ok(deadline - now)
}

fn timeout_or(e: std::io::Error) -> String {
    match e.kind() {
        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut => "timed out".into(),
        _ => e.to_string(),
    }
}

/// Connects without blocking past `deadline`.
fn connect(path: &str, deadline: Instant) -> Result<UnixStream, String> {
    use std::os::fd::FromRawFd;
    let bytes = path.as_bytes();
    let mut address: libc::sockaddr_un = unsafe { std::mem::zeroed() };
    if bytes.len() >= address.sun_path.len() {
        return Err("socket path too long".into());
    }
    address.sun_family = libc::AF_UNIX as libc::sa_family_t;
    for (dst, src) in address.sun_path.iter_mut().zip(bytes) {
        *dst = *src as libc::c_char;
    }
    unsafe {
        let fd = libc::socket(libc::AF_UNIX, libc::SOCK_STREAM, 0);
        if fd < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        let stream = UnixStream::from_raw_fd(fd);
        libc::fcntl(fd, libc::F_SETFL, libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK);
        let one: libc::c_int = 1;
        libc::setsockopt(fd, libc::SOL_SOCKET, libc::SO_NOSIGPIPE, (&one as *const libc::c_int).cast(),
                         std::mem::size_of::<libc::c_int>() as libc::socklen_t);
        let rc = libc::connect(fd, (&address as *const libc::sockaddr_un).cast(),
                               std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t);
        if rc != 0 {
            let err = std::io::Error::last_os_error();
            let pending = matches!(err.raw_os_error(), Some(libc::EINPROGRESS) | Some(libc::EAGAIN));
            if !pending {
                return Err(err.to_string());
            }
            let mut p = libc::pollfd { fd, events: libc::POLLOUT, revents: 0 };
            let ms = left(deadline)?.as_millis().min(i32::MAX as u128) as i32;
            if libc::poll(&mut p, 1, ms) <= 0 {
                return Err("timed out connecting".into());
            }
            let mut so_error: libc::c_int = 0;
            let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
            libc::getsockopt(fd, libc::SOL_SOCKET, libc::SO_ERROR, (&mut so_error as *mut libc::c_int).cast(), &mut len);
            if so_error != 0 {
                return Err(std::io::Error::from_raw_os_error(so_error).to_string());
            }
        }
        libc::fcntl(fd, libc::F_SETFL, libc::fcntl(fd, libc::F_GETFL) & !libc::O_NONBLOCK);
        Ok(stream)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};

    #[test]
    fn the_name_matches_the_apps() {
        // sha256("com.tako-core.terminal"), first 12 hex digits; the Swift
        // side derives the same name (ControlServer.socketPath).
        let path = default_path("com.tako-core.terminal").unwrap();
        let want: String = Sha256::digest(b"com.tako-core.terminal").iter().map(|b| format!("{b:02x}")).collect();
        assert!(path.ends_with(&format!("/tako-ctl-{}.sock", &want[..12])), "{path}");
    }

    #[test]
    fn one_request_gets_one_answer() {
        let (path, listener) = listen("echo");
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let req: Value = serde_json::from_str(&line).unwrap();
            let mut s = stream;
            writeln!(s, "{}", serde_json::json!({"ok": true, "result": {"echo": req["cmd"]}})).unwrap();
            s.flush().unwrap();
            std::thread::sleep(Duration::from_millis(20));
        });
        let answer = exchange(path.to_str().unwrap(), &serde_json::json!({"cmd": "tree"})).unwrap();
        server.join().unwrap();
        assert_eq!(answer["result"]["echo"], "tree");
    }

    fn listen(name: &str) -> (std::path::PathBuf, std::os::unix::net::UnixListener) {
        let dir = std::env::temp_dir().join(format!("takoctl-{name}-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("s.sock");
        let _ = std::fs::remove_file(&path);
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        (path, listener)
    }

    #[test]
    fn nothing_listening_is_a_request_never_sent() {
        let err = exchange_within("/nonexistent/tako.sock", &serde_json::json!({"cmd": "x"}),
                                  Duration::from_millis(300), MAX_ANSWER_BYTES).unwrap_err();
        assert!(!err.sent, "{err}");
    }

    #[test]
    fn a_server_that_never_answers_times_out() {
        let (path, listener) = listen("silent");
        let _hold = std::thread::spawn(move || {
            let (s, _) = listener.accept().unwrap();
            std::thread::sleep(Duration::from_secs(3));
            drop(s);
        });
        let started = Instant::now();
        let err = exchange_within(path.to_str().unwrap(), &serde_json::json!({"cmd": "x"}),
                                  Duration::from_millis(300), MAX_ANSWER_BYTES).unwrap_err();
        assert!(err.contains("timed out"), "{err}");
        // Delivered, then silence: the outcome is unknown, not "no Tako".
        assert!(err.sent);
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn a_trickling_answer_still_ends_at_the_deadline() {
        let (path, listener) = listen("drip");
        let _drip = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            for _ in 0..30 {
                if s.write_all(b" ").is_err() { break; }
                std::thread::sleep(Duration::from_millis(100));
            }
        });
        let started = Instant::now();
        let err = exchange_within(path.to_str().unwrap(), &serde_json::json!({"cmd": "x"}),
                                  Duration::from_millis(500), MAX_ANSWER_BYTES).unwrap_err();
        assert!(err.contains("timed out"), "{err}");
        assert!(started.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn an_oversized_json_line_is_refused_even_when_complete() {
        let (path, listener) = listen("bigline");
        let _big = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let line = format!("{}\n", serde_json::json!({"ok": true, "result": {"pad": "x".repeat(4000)}}));
            let _ = s.write_all(line.as_bytes());
        });
        let err = exchange_within(path.to_str().unwrap(), &serde_json::json!({"cmd": "x"}),
                                  Duration::from_secs(2), 1024).unwrap_err();
        assert!(err.contains("larger than"), "{err}");
    }

    #[test]
    fn an_oversized_answer_is_refused() {
        let (path, listener) = listen("big");
        let _big = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut buf = [0u8; 128];
            let _ = s.read(&mut buf);
            let _ = s.write_all(&vec![b'x'; 4096]);
            std::thread::sleep(Duration::from_millis(50));
        });
        let err = exchange_within(path.to_str().unwrap(), &serde_json::json!({"cmd": "x"}),
                                  Duration::from_secs(2), 1024).unwrap_err();
        assert!(err.contains("larger than"), "{err}");
    }

    #[test]
    fn stream_events_yields_lines_until_closed() {
        let (path, listener) = listen("stream");
        let server = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(s.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let req: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(req["cmd"], "events");
            writeln!(s, "{}", serde_json::json!({"cursor": 1, "type": "command_start"})).unwrap();
            writeln!(s, "{}", serde_json::json!({"cursor": 2, "type": "command_end"})).unwrap();
            writeln!(s, "{}", serde_json::json!({"cursor": 3, "type": "status"})).unwrap();
            s.flush().unwrap();
            drop(s);
        });

        let mut lines = Vec::new();
        let res = stream_events(path.to_str().unwrap(), &serde_json::json!({"cmd": "events"}), |l| {
            lines.push(l.to_string());
            Ok(())
        });
        server.join().unwrap();
        assert!(res.is_ok());
        assert_eq!(lines.len(), 3);
        assert!(lines[0].contains("\"cursor\":1"));
        assert!(lines[1].contains("\"cursor\":2"));
        assert!(lines[2].contains("\"cursor\":3"));
    }

    #[test]
    fn stream_events_aborts_when_callback_fails() {
        let (path, listener) = listen("stream-abort");
        let server = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let _ = writeln!(s, "{}", serde_json::json!({"cursor": 1}));
            let _ = writeln!(s, "{}", serde_json::json!({"cursor": 2}));
            let _ = s.flush();
        });

        let mut count = 0;
        let res = stream_events(path.to_str().unwrap(), &serde_json::json!({"cmd": "events"}), |_| {
            count += 1;
            Err("stop requested".to_string())
        });
        server.join().unwrap();
        assert!(res.is_err());
        assert_eq!(count, 1);
        let err = res.unwrap_err();
        assert!(err.sent);
        assert!(err.contains("stop requested"));
    }
}
