/*
 * tako — Unix socket request regressions
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::*;
use std::io::{BufRead, BufReader};

#[test]
fn the_name_matches_the_apps() {
    // sha256("com.tako-core.terminal"), first 12 hex digits; the Swift
    // side derives the same name (ControlServer.socketPath).
    let path = default_path("com.tako-core.terminal").unwrap();
    let want: String = Sha256::digest(b"com.tako-core.terminal")
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    assert!(
        path.ends_with(&format!("/tako-ctl-{}.sock", &want[..12])),
        "{path}"
    );
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
        writeln!(
            s,
            "{}",
            serde_json::json!({"ok": true, "result": {"echo": req["cmd"]}})
        )
        .unwrap();
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

/// Tako answered and closed its end before takoctl read: the answer is
/// read, not lost to "unknown outcome: Invalid argument (os error 22)".
#[test]
fn an_answer_left_by_a_closed_peer_is_still_read() {
    let (mut ours, mut theirs) = UnixStream::pair().unwrap();
    ours.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
    writeln!(
        theirs,
        "{}",
        serde_json::json!({"ok": true, "result": {"name": "Default"}})
    )
    .unwrap();
    drop(theirs);
    let answer = read_answer(
        &mut ours,
        Instant::now() + Duration::from_secs(2),
        MAX_ANSWER_BYTES,
    )
    .unwrap();
    assert_eq!(answer["result"]["name"], "Default");
}

/// Why: macOS will not set a timeout on a socket whose peer has closed.
#[cfg(target_os = "macos")]
#[test]
fn macos_refuses_a_timeout_once_the_peer_has_closed() {
    let (ours, theirs) = UnixStream::pair().unwrap();
    drop(theirs);
    let err = ours
        .set_read_timeout(Some(Duration::from_secs(1)))
        .unwrap_err();
    assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput, "{err}");
}

#[test]
fn nothing_listening_is_a_request_never_sent() {
    let err = exchange_within(
        "/nonexistent/tako.sock",
        &serde_json::json!({"cmd": "x"}),
        Duration::from_millis(300),
        MAX_ANSWER_BYTES,
    )
    .unwrap_err();
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
    let err = exchange_within(
        path.to_str().unwrap(),
        &serde_json::json!({"cmd": "x"}),
        Duration::from_millis(300),
        MAX_ANSWER_BYTES,
    )
    .unwrap_err();
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
            if s.write_all(b" ").is_err() {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
    });
    let started = Instant::now();
    let err = exchange_within(
        path.to_str().unwrap(),
        &serde_json::json!({"cmd": "x"}),
        Duration::from_millis(500),
        MAX_ANSWER_BYTES,
    )
    .unwrap_err();
    assert!(err.contains("timed out"), "{err}");
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn an_oversized_json_line_is_refused_even_when_complete() {
    let (path, listener) = listen("bigline");
    let _big = std::thread::spawn(move || {
        let (mut s, _) = listener.accept().unwrap();
        let line = format!(
            "{}\n",
            serde_json::json!({"ok": true, "result": {"pad": "x".repeat(4000)}})
        );
        let _ = s.write_all(line.as_bytes());
    });
    let err = exchange_within(
        path.to_str().unwrap(),
        &serde_json::json!({"cmd": "x"}),
        Duration::from_secs(2),
        1024,
    )
    .unwrap_err();
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
    let err = exchange_within(
        path.to_str().unwrap(),
        &serde_json::json!({"cmd": "x"}),
        Duration::from_secs(2),
        1024,
    )
    .unwrap_err();
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
        writeln!(
            s,
            "{}",
            serde_json::json!({"cursor": 1, "type": "command_start"})
        )
        .unwrap();
        writeln!(
            s,
            "{}",
            serde_json::json!({"cursor": 2, "type": "command_end"})
        )
        .unwrap();
        writeln!(s, "{}", serde_json::json!({"cursor": 3, "type": "status"})).unwrap();
        s.flush().unwrap();
        drop(s);
    });

    let mut lines = Vec::new();
    let res = stream_events(
        path.to_str().unwrap(),
        &serde_json::json!({"cmd": "events"}),
        |l| {
            lines.push(l.to_string());
            Ok(())
        },
    );
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
    let res = stream_events(
        path.to_str().unwrap(),
        &serde_json::json!({"cmd": "events"}),
        |_| {
            count += 1;
            Err("stop requested".to_string())
        },
    );
    server.join().unwrap();
    assert!(res.is_err());
    assert_eq!(count, 1);
    let err = res.unwrap_err();
    assert!(err.sent);
    assert!(err.contains("stop requested"));
}
