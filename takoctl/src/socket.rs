//! Finding the app's control socket and talking to it.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

use serde_json::Value;
use sha2::{Digest, Sha256};

/// How long to wait for the app to take the request and to answer.
const TIMEOUT: Duration = Duration::from_secs(30);

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

/// Sends one request line and reads the one-line answer.
pub fn exchange(path: &str, request: &Value) -> Result<Value, String> {
    let mut stream = UnixStream::connect(path).map_err(|e| e.to_string())?;
    stream.set_read_timeout(Some(TIMEOUT)).map_err(|e| e.to_string())?;
    stream.set_write_timeout(Some(TIMEOUT)).map_err(|e| e.to_string())?;
    let mut line = serde_json::to_vec(request).map_err(|e| e.to_string())?;
    line.push(b'\n');
    stream.write_all(&line).map_err(|e| e.to_string())?;
    let mut answer = String::new();
    BufReader::new(stream).read_line(&mut answer).map_err(|e| e.to_string())?;
    if answer.is_empty() {
        return Err("the connection closed without an answer".into());
    }
    serde_json::from_str(&answer).map_err(|e| format!("unreadable answer: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

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
        let dir = std::env::temp_dir().join(format!("takoctl-test-{}", std::process::id()));
        let _ = std::fs::create_dir_all(&dir);
        let path = dir.join("s.sock");
        let _ = std::fs::remove_file(&path);
        let listener = std::os::unix::net::UnixListener::bind(&path).unwrap();
        let server = std::thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let req: Value = serde_json::from_str(&line).unwrap();
            let mut s = stream;
            writeln!(s, "{}", serde_json::json!({"ok": true, "result": {"echo": req["cmd"]}})).unwrap();
        });
        let answer = exchange(path.to_str().unwrap(), &serde_json::json!({"cmd": "tree"})).unwrap();
        server.join().unwrap();
        assert_eq!(answer["result"]["echo"], "tree");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
