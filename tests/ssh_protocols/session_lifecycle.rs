/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::server::*;

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
        assert!(
            out.contains("\u{4e16}\u{754c}"),
            "CJK did not survive: {out:?}"
        );
        assert!(
            out.contains("\u{43f}\u{440}\u{438}\u{432}\u{435}\u{442}"),
            "Cyrillic did not survive"
        );
    });
}

#[test]
fn a_server_is_gone_once_its_test_ends() {
    let port = {
        let Some(server) =
            require_server(TestServer::start("ed25519", "ed25519", ""), "cleanup test")
        else {
            return;
        };
        let port = server.port;
        assert!(
            TcpStream::connect_timeout(
                &format!("127.0.0.1:{port}").parse().unwrap(),
                Duration::from_millis(200)
            )
            .is_ok()
        );
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
