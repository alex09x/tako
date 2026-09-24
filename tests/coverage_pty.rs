#![cfg(feature = "pty")]

use std::io::{Read, Write};
use std::os::unix::io::AsRawFd;
use std::time::{Duration, Instant};
use tako_core::pty::Pty;

/// Reads and discards the master's output until the child side closes, then
/// reaps the child. On macOS a process exiting on a pty blocks in close until
/// its pending output has been read, so waiting without draining can hang
/// forever there (Linux does not block). Bounded by a deadline so a child that
/// never exits fails the test instead of hanging it.
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

/// Helper that polls the PTY master fd until `marker` appears in captured output
/// or the deadline expires. Fails with captured output on timeout or unexpected error.
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
fn test_spawn_command_basic_and_pid() {
    let mut pty = Pty::spawn_command(&["/bin/sh", "-c", "echo pty_basic_test"], &[], 24, 80);
    assert!(pty.pid() > 0, "pid must be positive, got {}", pty.pid());
    let out = read_until(&mut pty, "pty_basic_test", Duration::from_secs(5))
        .unwrap_or_else(|e| panic!("{e}"));
    assert!(out.contains("pty_basic_test"));
    let status = drain_and_wait(&mut pty);
    assert_eq!(status, 0);
}

#[test]
fn test_spawn_shell_convenience_and_io() {
    let mut pty = Pty::spawn("/bin/sh", 24, 80);
    assert!(pty.pid() > 0);
    pty.master.write_all(b"echo hello_from_shell\n").unwrap();
    pty.master.flush().unwrap();
    let out = read_until(&mut pty, "hello_from_shell", Duration::from_secs(5))
        .unwrap_or_else(|e| panic!("{e}"));
    assert!(out.contains("hello_from_shell"));
    pty.master.write_all(b"exit 0\n").unwrap();
    pty.master.flush().unwrap();
    assert_eq!(drain_and_wait(&mut pty), 0);
}

#[test]
fn test_spawn_command_env_vars() {
    let mut pty = Pty::spawn_command(
        &["/bin/sh", "-c", "printf 'VAR_A=%s;VAR_B=%s\\n' \"$VAR_A\" \"$VAR_B\""],
        &[("VAR_A", "apple_pie"), ("VAR_B", "banana_split")],
        24,
        80,
    );
    let out = read_until(
        &mut pty,
        "VAR_A=apple_pie;VAR_B=banana_split",
        Duration::from_secs(5),
    )
    .unwrap_or_else(|e| panic!("{e}"));
    assert!(out.contains("VAR_A=apple_pie;VAR_B=banana_split"));
    assert_eq!(drain_and_wait(&mut pty), 0);
}

#[test]
fn test_spawn_command_default_term_env() {
    let mut pty = Pty::spawn_command(
        &["/bin/sh", "-c", "printf 'TERM=%s\\n' \"$TERM\""],
        &[],
        24,
        80,
    );
    let out = read_until(&mut pty, "TERM=xterm-256color", Duration::from_secs(5))
        .unwrap_or_else(|e| panic!("{e}"));
    assert!(out.contains("TERM=xterm-256color"));
    assert_eq!(drain_and_wait(&mut pty), 0);
}

#[test]
fn test_spawn_command_custom_term_override() {
    let mut pty = Pty::spawn_command(
        &["/bin/sh", "-c", "printf 'TERM=%s\\n' \"$TERM\""],
        &[("TERM", "vt100-custom")],
        24,
        80,
    );
    let out = read_until(&mut pty, "TERM=vt100-custom", Duration::from_secs(5))
        .unwrap_or_else(|e| panic!("{e}"));
    assert!(out.contains("TERM=vt100-custom"));
    assert_eq!(drain_and_wait(&mut pty), 0);
}

#[test]
fn test_resize_stty_size_interactive() {
    let mut pty = Pty::spawn("/bin/sh", 24, 80);
    assert!(pty.pid() > 0);

    pty.master.write_all(b"stty size\n").unwrap();
    pty.master.flush().unwrap();
    let out1 = read_until(&mut pty, "24 80", Duration::from_secs(5))
        .unwrap_or_else(|e| panic!("{e}"));
    assert!(out1.contains("24 80"));

    pty.resize(37, 105);
    pty.master.write_all(b"stty size\n").unwrap();
    pty.master.flush().unwrap();
    let out2 = read_until(&mut pty, "37 105", Duration::from_secs(5))
        .unwrap_or_else(|e| panic!("{e}"));
    assert!(out2.contains("37 105"));

    pty.resize(52, 133);
    pty.master.write_all(b"stty size\n").unwrap();
    pty.master.flush().unwrap();
    let out3 = read_until(&mut pty, "52 133", Duration::from_secs(5))
        .unwrap_or_else(|e| panic!("{e}"));
    assert!(out3.contains("52 133"));

    pty.master.write_all(b"exit 0\n").unwrap();
    pty.master.flush().unwrap();
    assert_eq!(drain_and_wait(&mut pty), 0);
}

#[test]
fn test_resize_stty_size_direct() {
    let mut pty = Pty::spawn_command(&["stty", "size"], &[], 42, 115);
    let out = read_until(&mut pty, "42 115", Duration::from_secs(5))
        .unwrap_or_else(|e| panic!("{e}"));
    assert!(out.contains("42 115"));
    assert_eq!(drain_and_wait(&mut pty), 0);
}

#[test]
fn test_terminate_and_wait_signal() {
    let mut pty = Pty::spawn_command(&["sleep", "30"], &[], 24, 80);
    assert!(pty.pid() > 0);
    pty.terminate();
    let status = drain_and_wait(&mut pty);
    assert_eq!(
        status,
        128 + libc::SIGTERM,
        "terminated process should exit with 128 + SIGTERM (got {status})"
    );
}

#[test]
fn test_wait_exit_codes() {
    for code in [0, 1, 3, 42, 100] {
        let cmd = format!("exit {code}");
        let mut pty = Pty::spawn_command(&["/bin/sh", "-c", &cmd], &[], 24, 80);
        assert_eq!(drain_and_wait(&mut pty), code, "expected exit code {code}");
    }
}

#[test]
fn test_wait_after_child_already_reaped() {
    let mut pty = Pty::spawn_command(&["/bin/sh", "-c", "exit 7"], &[], 24, 80);
    assert_eq!(drain_and_wait(&mut pty), 7);
    assert_eq!(pty.wait(), -1, "second wait on reaped pid must return -1");
}

#[test]
fn test_exec_failure_exit_127() {
    let mut pty = Pty::spawn_command(&["/nonexistent_binary_xyz_404"], &[], 24, 80);
    assert!(pty.pid() > 0);
    assert_eq!(drain_and_wait(&mut pty), 127, "failed execvp must cause child to exit 127");
}

#[test]
#[should_panic(expected = "spawn_command needs a program to run")]
fn test_spawn_command_empty_argv_panics() {
    Pty::spawn_command(&[], &[], 24, 80);
}

#[test]
#[should_panic(expected = "argv entry contains a NUL")]
fn test_spawn_command_nul_in_argv_panics() {
    Pty::spawn_command(&["echo\0bad"], &[], 24, 80);
}

#[test]
#[should_panic(expected = "env key contains a NUL")]
fn test_spawn_command_nul_in_env_key_panics() {
    Pty::spawn_command(&["echo"], &[("BAD\0KEY", "value")], 24, 80);
}

#[test]
#[should_panic(expected = "env value contains a NUL")]
fn test_spawn_command_nul_in_env_val_panics() {
    Pty::spawn_command(&["echo"], &[("KEY", "bad\0value")], 24, 80);
}

#[test]
fn test_master_clone_and_bidirectional_flow() {
    let mut pty = Pty::spawn("/bin/sh", 24, 80);
    let mut sink = pty.master.try_clone().expect("try_clone pty master");

    sink.write_all(b"printf 'clone_stream_test\\n'\n").unwrap();
    sink.flush().unwrap();

    let out = read_until(&mut pty, "clone_stream_test", Duration::from_secs(5))
        .unwrap_or_else(|e| panic!("{e}"));
    assert!(out.contains("clone_stream_test"));

    sink.write_all(b"exit 0\n").unwrap();
    sink.flush().unwrap();
    assert_eq!(drain_and_wait(&mut pty), 0);
}

#[test]
fn test_pty_drop_closes_master_cleanly() {
    let pid;
    {
        let pty = Pty::spawn_command(&["sleep", "1"], &[], 24, 80);
        pid = pty.pid();
        assert!(pid > 0);
    }
    let mut status = 0;
    unsafe {
        libc::waitpid(pid, &mut status, 0);
    }
}
