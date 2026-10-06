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
    assert!(
        result.is_err(),
        "an encrypted key opened without its passphrase"
    );
}
