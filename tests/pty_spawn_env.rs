#![cfg(feature = "pty")]

//! Fork-safety coverage for `Pty::spawn_command`: the envp and the resolved
//! executable path are built entirely in the parent before `fork`, so the
//! child only does async-signal-safe work. These tests exercise the
//! observable behaviour that construction has to preserve: the caller's
//! variables and `TERM` reach the child, so does an environment variable the
//! test process merely inherited (never passed through `env`), a bare
//! program name is still found via `PATH`, and a bare name that isn't on
//! `PATH` still exits 127 like `execvp` would.

use std::io::Read;
use std::os::unix::io::AsRawFd;
use std::time::{Duration, Instant};
use tako_core::pty::Pty;

/// Reads and discards the master's output until the child side closes, then
/// reaps the child. On macOS a process exiting on a pty blocks in close until
/// its pending output has been read, so waiting without draining can hang
/// forever there (Linux does not block). Bounded by a deadline so a child
/// that never exits fails the test instead of hanging it.
fn drain_and_wait(pty: &mut Pty) -> i32 {
    let deadline = Instant::now() + Duration::from_secs(10);
    let fd = pty.master.as_raw_fd();
    let mut buf = [0u8; 4096];
    while Instant::now() < deadline {
        let mut pfd = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
        let ret = unsafe { libc::poll(&mut pfd, 1, 200) };
        if ret < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
        if ret == 0 {
            continue;
        }
        match pty.master.read(&mut buf) {
            Ok(0) => break,
            Ok(_) => {}
            Err(e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(_) => break, // EIO: the slave side is gone
        }
    }
    assert!(Instant::now() < deadline, "child did not close its pty within 10 s");
    pty.wait()
}

/// Polls the PTY master fd until `marker` appears in captured output or the
/// deadline expires. Fails with captured output on timeout or unexpected
/// error -- never sleeps a fixed amount and hopes the child was fast enough.
fn read_until(pty: &mut Pty, marker: &str, timeout: Duration) -> Result<String, String> {
    let start = Instant::now();
    let mut captured = Vec::new();
    let mut buf = [0u8; 1024];
    let fd = pty.master.as_raw_fd();

    while start.elapsed() < timeout {
        let remaining = timeout.saturating_sub(start.elapsed());
        let timeout_ms = remaining.as_millis().min(200) as libc::c_int;

        let mut pfd = libc::pollfd {
            fd,
            events: libc::POLLIN,
            revents: 0,
        };

        let ret = unsafe { libc::poll(&mut pfd, 1, timeout_ms) };
        if ret < 0 {
            let err = std::io::Error::last_os_error();
            if err.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            return Err(format!(
                "poll failed: {err}; captured so far: {:?}",
                String::from_utf8_lossy(&captured)
            ));
        }

        if ret > 0 && (pfd.revents & (libc::POLLIN | libc::POLLHUP | libc::POLLERR) != 0) {
            match pty.master.read(&mut buf) {
                Ok(0) => {
                    let text = String::from_utf8_lossy(&captured);
                    if text.contains(marker) {
                        return Ok(text.into_owned());
                    }
                    return Err(format!(
                        "EOF reached before marker {:?}; captured: {:?}",
                        marker, text
                    ));
                }
                Ok(n) => {
                    captured.extend_from_slice(&buf[..n]);
                    let text = String::from_utf8_lossy(&captured);
                    if text.contains(marker) {
                        return Ok(text.into_owned());
                    }
                }
                Err(e) if e.raw_os_error() == Some(libc::EIO) => {
                    let text = String::from_utf8_lossy(&captured);
                    if text.contains(marker) {
                        return Ok(text.into_owned());
                    }
                    return Err(format!(
                        "EIO (child closed PTY) before marker {:?}; captured: {:?}",
                        marker, text
                    ));
                }
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => continue,
                Err(e) => {
                    return Err(format!(
                        "read failed: {e}; captured: {:?}",
                        String::from_utf8_lossy(&captured)
                    ));
                }
            }
        }

        let text = String::from_utf8_lossy(&captured);
        if text.contains(marker) {
            return Ok(text.into_owned());
        }
    }

    Err(format!(
        "timed out after {:?} waiting for marker {:?}; captured: {:?}",
        timeout,
        marker,
        String::from_utf8_lossy(&captured)
    ))
}

#[test]
fn test_child_sees_callers_vars_and_term() {
    let mut pty = Pty::spawn_command(
        &[
            "/bin/sh",
            "-c",
            "printf 'CALLER=%s;TERM=%s\\n' \"$CALLER_VAR\" \"$TERM\"",
        ],
        &[("CALLER_VAR", "from_the_caller")],
        24,
        80,
    );
    let out = read_until(
        &mut pty,
        "CALLER=from_the_caller;TERM=xterm-256color",
        Duration::from_secs(5),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    assert!(out.contains("CALLER=from_the_caller;TERM=xterm-256color"));
    assert_eq!(drain_and_wait(&mut pty), 0);
}

/// A variable the test process merely inherited (never passed through the
/// `env` slice) must still reach the child: the envp built before `fork` has
/// to start from the full inherited environment, not just the caller's pairs.
/// Uses HOME, which every test process inherits, rather than setting a
/// variable: changing the environment while other tests fork is itself unsafe.
#[test]
fn test_child_sees_inherited_env_var() {
    let home = std::env::var("HOME").expect("test process has HOME");
    let mut pty = Pty::spawn_command(&["/bin/sh", "-c", "printf 'HOME=%s\\n' \"$HOME\""], &[], 24, 80);
    let expected = format!("HOME={home}");
    let out = read_until(&mut pty, &expected, Duration::from_secs(5)).unwrap_or_else(|e| panic!("{e}"));
    assert!(out.contains(&expected));
    assert_eq!(drain_and_wait(&mut pty), 0);
}

/// A bare program name (no slash) must still be found by searching `PATH` in
/// the parent, since `execve` -- unlike `execvp` -- never searches `PATH`
/// itself.
#[test]
fn test_bare_program_name_found_via_path() {
    let mut pty = Pty::spawn_command(&["echo", "bare_path_lookup_ok"], &[], 24, 80);
    assert!(pty.pid() > 0);
    let out = read_until(&mut pty, "bare_path_lookup_ok", Duration::from_secs(5))
        .unwrap_or_else(|e| panic!("{e}"));
    assert!(out.contains("bare_path_lookup_ok"));
    assert_eq!(drain_and_wait(&mut pty), 0);
}

/// A bare name that isn't on `PATH` must still make the child exit 127, the
/// same outcome a failed `execvp` PATH search would have produced.
#[test]
fn test_missing_bare_program_exits_127() {
    let mut pty = Pty::spawn_command(
        &["definitely_not_a_real_command_xyz_987"],
        &[],
        24,
        80,
    );
    assert!(pty.pid() > 0);
    assert_eq!(
        drain_and_wait(&mut pty),
        127,
        "a bare name missing from PATH must exit 127"
    );
}
