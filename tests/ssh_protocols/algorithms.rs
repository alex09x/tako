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
fn negotiates_curve25519() {
    with_server(
        "ed25519",
        "ed25519",
        "KexAlgorithms curve25519-sha256",
        |server| {
            let out = server.shell_says(PROBE).expect("connection failed");
            assert!(out.contains("TAKO_MARKER"), "no shell output: {out:?}");
        },
    );
}

#[test]
fn negotiates_ecdh_over_the_nist_curves() {
    for curve in [
        "ecdh-sha2-nistp256",
        "ecdh-sha2-nistp384",
        "ecdh-sha2-nistp521",
    ] {
        with_server(
            "ed25519",
            "ed25519",
            &format!("KexAlgorithms {curve}"),
            |server| {
                let out = server
                    .shell_says(PROBE)
                    .unwrap_or_else(|e| panic!("{curve} failed: {e}"));
                assert!(out.contains("TAKO_MARKER"), "{curve}: no shell output");
            },
        );
    }
}

#[test]
fn negotiates_finite_field_diffie_hellman() {
    // The fallback an old or conservatively configured server leaves on.
    for kex in [
        "diffie-hellman-group14-sha256",
        "diffie-hellman-group16-sha512",
    ] {
        with_server(
            "ed25519",
            "ed25519",
            &format!("KexAlgorithms {kex}"),
            |server| {
                let out = server
                    .shell_says(PROBE)
                    .unwrap_or_else(|e| panic!("{kex} failed: {e}"));
                assert!(out.contains("TAKO_MARKER"), "{kex}: no shell output");
            },
        );
    }
}

// ── Ciphers and MACs ─────────────────────────────────────────────────────────

#[test]
fn negotiates_each_supported_cipher() {
    for cipher in [
        "chacha20-poly1305@openssh.com",
        "aes256-gcm@openssh.com",
        "aes128-ctr",
        "aes192-ctr",
        "aes256-ctr",
    ] {
        with_server(
            "ed25519",
            "ed25519",
            &format!("Ciphers {cipher}"),
            |server| {
                let out = server
                    .shell_says(PROBE)
                    .unwrap_or_else(|e| panic!("{cipher} failed: {e}"));
                assert!(out.contains("TAKO_MARKER"), "{cipher}: no shell output");
            },
        );
    }
}

#[test]
fn negotiates_each_supported_mac() {
    // GCM and chacha20 carry their own integrity, so a MAC only matters with
    // a CTR cipher -- pinning one alongside is what makes this test real.
    for mac in [
        "hmac-sha2-256",
        "hmac-sha2-512",
        "hmac-sha2-256-etm@openssh.com",
        "hmac-sha2-512-etm@openssh.com",
    ] {
        let extra = format!("Ciphers aes256-ctr\nMACs {mac}");
        with_server("ed25519", "ed25519", &extra, |server| {
            let out = server
                .shell_says(PROBE)
                .unwrap_or_else(|e| panic!("{mac} failed: {e}"));
            assert!(out.contains("TAKO_MARKER"), "{mac}: no shell output");
        });
    }
}

// ── No common ground ─────────────────────────────────────────────────────────

/// A server that shares no cipher with us has to be reported, promptly. The
/// failure mode that matters on a phone is not "refused" but "spins forever
/// while the user waits", so this asserts it ends.
#[test]
fn a_server_with_no_shared_cipher_fails_rather_than_hanging() {
    // 3des-cbc is old enough that russh does not offer it.
    with_server("ed25519", "ed25519", "Ciphers 3des-cbc", |server| {
        let started = Instant::now();
        let result = server.shell_says(PROBE);
        assert!(result.is_err(), "connected despite no shared cipher");
        assert!(
            started.elapsed() < Duration::from_secs(25),
            "took {:?} to give up",
            started.elapsed()
        );
    });
}

// ── The shell itself ─────────────────────────────────────────────────────────
