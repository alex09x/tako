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
    Ok(format!(
        "{}/tako-ctl-{}.sock",
        dir.trim_end_matches('/'),
        &hex[..12]
    ))
}

pub fn resolve_path(
    bundle_id: &str,
    socket_arg: Option<&str>,
    explicit_bundle: bool,
    inherited: Option<&str>,
) -> Result<String, String> {
    if let Some(s) = socket_arg {
        Ok(s.to_string())
    } else if let Some(inh) = inherited.filter(|_| !explicit_bundle) {
        Ok(inh.to_string())
    } else {
        default_path(bundle_id)
    }
}

#[cfg(target_os = "macos")]
fn user_temp_dir() -> Result<String, String> {
    let mut buf = vec![0u8; libc::PATH_MAX as usize];
    let n = unsafe {
        libc::confstr(
            libc::_CS_DARWIN_USER_TEMP_DIR,
            buf.as_mut_ptr().cast(),
            buf.len(),
        )
    };
    if n == 0 || n > buf.len() {
        return Err("no per-user temporary directory".into());
    }
    buf.truncate(n - 1);
    String::from_utf8(buf).map_err(|_| "temporary directory is not UTF-8".into())
}

#[cfg(not(target_os = "macos"))]
fn user_temp_dir() -> Result<String, String> {
    Ok(std::env::var("TMPDIR").unwrap_or_else(|_| "/tmp".to_string()))
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

pub fn exchange_within(
    path: &str,
    request: &Value,
    limit: Duration,
    max: usize,
) -> Result<Value, Failure> {
    let unsent = |message: String| Failure {
        message,
        sent: false,
    };
    let deadline = Instant::now() + limit;
    let mut stream = connect(path, deadline).map_err(unsent)?;
    // While the connection is surely open: once Tako has answered and closed
    // its end, macOS refuses to change a socket's timeouts (EINVAL).
    stream
        .set_read_timeout(Some(left(deadline).map_err(unsent)?))
        .map_err(|e| unsent(e.to_string()))?;
    let mut line = serde_json::to_vec(request).map_err(|e| unsent(e.to_string()))?;
    line.push(b'\n');
    let mut written = 0;
    while written < line.len() {
        stream
            .set_write_timeout(Some(left(deadline).map_err(unsent)?))
            .map_err(|e| unsent(e.to_string()))?;
        match stream.write(&line[written..]) {
            Ok(0) => return Err(unsent("the connection closed".into())),
            Ok(n) => written += n,
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(unsent(timeout_or(e))),
        }
    }
    read_answer(&mut stream, deadline, max)
}

/// Reads the one-line answer. Tako may have written it and closed its end
/// before the first read: the answer is still there to read, though the
/// socket no longer takes a new timeout, so the one set before stands.
fn read_answer(stream: &mut UnixStream, deadline: Instant, max: usize) -> Result<Value, Failure> {
    let sent = |message: String| Failure {
        message,
        sent: true,
    };
    let mut answer = Vec::new();
    let mut chunk = [0u8; 64 * 1024];
    loop {
        if let Err(e) = stream.set_read_timeout(Some(left(deadline).map_err(sent)?))
            && e.kind() != std::io::ErrorKind::InvalidInput
        {
            return Err(sent(format!("setting the read timeout: {e}")));
        }
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
            Err(e) => return Err(sent(format!("reading the answer: {}", timeout_or(e)))),
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
    let unsent = |message: String| Failure {
        message,
        sent: false,
    };
    let sent = |message: String| Failure {
        message,
        sent: true,
    };
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut stream = connect(path, deadline).map_err(unsent)?;
    let mut line = serde_json::to_vec(request).map_err(|e| unsent(e.to_string()))?;
    line.push(b'\n');
    stream.write_all(&line).map_err(|e| unsent(e.to_string()))?;

    use std::io::BufRead;
    let reader = std::io::BufReader::new(stream);
    for line_res in reader.lines() {
        let text = line_res.map_err(|e| sent(e.to_string()))?;
        if text.trim().is_empty() {
            continue;
        }
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
        libc::fcntl(
            fd,
            libc::F_SETFL,
            libc::fcntl(fd, libc::F_GETFL) | libc::O_NONBLOCK,
        );
        #[cfg(any(
            target_os = "macos",
            target_os = "ios",
            target_os = "freebsd",
            target_os = "openbsd",
            target_os = "netbsd"
        ))]
        {
            let one: libc::c_int = 1;
            libc::setsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_NOSIGPIPE,
                (&one as *const libc::c_int).cast(),
                std::mem::size_of::<libc::c_int>() as libc::socklen_t,
            );
        }
        let rc = libc::connect(
            fd,
            (&address as *const libc::sockaddr_un).cast(),
            std::mem::size_of::<libc::sockaddr_un>() as libc::socklen_t,
        );
        if rc != 0 {
            let err = std::io::Error::last_os_error();
            let pending = matches!(
                err.raw_os_error(),
                Some(libc::EINPROGRESS) | Some(libc::EAGAIN)
            );
            if !pending {
                return Err(err.to_string());
            }
            let mut p = libc::pollfd {
                fd,
                events: libc::POLLOUT,
                revents: 0,
            };
            let ms = left(deadline)?.as_millis().min(i32::MAX as u128) as i32;
            if libc::poll(&mut p, 1, ms) <= 0 {
                return Err("timed out connecting".into());
            }
            let mut so_error: libc::c_int = 0;
            let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
            libc::getsockopt(
                fd,
                libc::SOL_SOCKET,
                libc::SO_ERROR,
                (&mut so_error as *mut libc::c_int).cast(),
                &mut len,
            );
            if so_error != 0 {
                return Err(std::io::Error::from_raw_os_error(so_error).to_string());
            }
        }
        libc::fcntl(
            fd,
            libc::F_SETFL,
            libc::fcntl(fd, libc::F_GETFL) & !libc::O_NONBLOCK,
        );
        Ok(stream)
    }
}

#[cfg(test)]
mod tests;
