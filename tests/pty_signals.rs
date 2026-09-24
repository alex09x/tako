#![cfg(feature = "pty")]
// A program started in the terminal gets default signal handling, whatever
// the host process ignores. Its own binary: it changes process-wide signal
// dispositions.

use std::io::Read;
use tako_core::pty::Pty;

#[test]
fn a_hangup_ends_the_child_even_when_the_host_ignores_hangups() {
    unsafe {
        libc::signal(libc::SIGHUP, libc::SIG_IGN);
    }
    // The child sends itself a hangup, then says it survived. With the
    // host's "ignore" inherited, it would.
    let mut pty = Pty::spawn_command(&["/bin/sh", "-c", "kill -HUP $$; echo survived"], &[], 24, 80);
    let mut out = String::new();
    let mut buf = [0u8; 4096];
    loop {
        match pty.master.read(&mut buf) {
            Ok(0) | Err(_) => break,
            Ok(n) => out.push_str(&String::from_utf8_lossy(&buf[..n])),
        }
    }
    let status = pty.wait();
    unsafe {
        libc::signal(libc::SIGHUP, libc::SIG_DFL);
    }
    assert!(!out.contains("survived"), "the child ignored SIGHUP: {out:?}");
    assert_ne!(status, 0);
}
