/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use serde_json::Value;
use crate::Options;

pub fn decode_base64(s: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity((s.len() * 3) / 4);
    let mut buf: u32 = 0;
    let mut bits: u32 = 0;
    for &b in s.as_bytes() {
        let val = match b {
            b'A'..=b'Z' => (b - b'A') as u32,
            b'a'..=b'z' => (b - b'a' + 26) as u32,
            b'0'..=b'9' => (b - b'0' + 52) as u32,
            b'+' => 62,
            b'/' => 63,
            b'=' | b'\r' | b'\n' | b' ' => continue,
            _ => return Err(format!("invalid base64 character: {}", b as char)),
        };
        buf = (buf << 6) | val;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
            buf &= (1 << bits) - 1;
        }
    }
    Ok(out)
}

pub fn random_hex(num_bytes: usize) -> String {
    let mut buf = vec![0u8; num_bytes];
    let ok = std::fs::File::open("/dev/urandom")
        .and_then(|mut f| std::io::Read::read_exact(&mut f, &mut buf))
        .is_ok();
    if !ok {
        use sha2::{Digest, Sha256};
        let mut hasher = Sha256::new();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default();
        hasher.update(now.as_nanos().to_le_bytes());
        hasher.update(std::process::id().to_le_bytes());
        let hash = hasher.finalize();
        for (i, b) in hash.iter().take(num_bytes).enumerate() {
            buf[i] = *b;
        }
    }
    buf.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn write_exclusive_temp_file(id: &str, bytes: &[u8]) -> Result<std::path::PathBuf, String> {
    let temp_dir = std::env::temp_dir();
    let clean_id: String = id
        .chars()
        .filter(|c| c.is_alphanumeric() || *c == '-' || *c == '_')
        .collect();
    let safe_id = if clean_id.is_empty() {
        "pane"
    } else {
        &clean_id
    };
    let mut last_err = None;

    for _ in 0..5 {
        let token = random_hex(16);
        let path = temp_dir.join(format!("tako-screenshot-{safe_id}-{token}.png"));
        let mut opts = std::fs::OpenOptions::new();
        opts.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            opts.mode(0o600);
            opts.custom_flags(libc::O_NOFOLLOW);
        }
        match opts.open(&path) {
            Ok(mut file) => {
                use std::io::Write;
                if let Err(e) = file.write_all(bytes) {
                    let _ = std::fs::remove_file(&path);
                    return Err(format!(
                        "failed to write screenshot data to {}: {e}",
                        path.display()
                    ));
                }
                let _ = file.flush();
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
                }
                return Ok(path);
            }
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                last_err = Some(e);
                continue;
            }
            Err(e) => {
                return Err(format!(
                    "failed to create private screenshot file at {}: {e}",
                    path.display()
                ));
            }
        }
    }
    Err(format!(
        "failed to create exclusive screenshot file after multiple attempts: {last_err:?}"
    ))
}

pub fn handle_screenshot_output(opts: &Options, result: &Value) -> Result<String, String> {
    let b64 = result["data"]
        .as_str()
        .ok_or_else(|| "missing screenshot data in response".to_string())?;
    let bytes = decode_base64(b64)?;
    let id = result["id"].as_str().unwrap_or("pane");
    let width = result["width"].as_f64().unwrap_or(0.0) as u64;
    let height = result["height"].as_f64().unwrap_or(0.0) as u64;

    if let Some(out_path) = opts.args.get("out").and_then(Value::as_str) {
        let path = std::path::Path::new(out_path);
        if let Some(parent) = path.parent()
            && !parent.as_os_str().is_empty()
        {
            let _ = std::fs::create_dir_all(parent);
        }
        std::fs::write(path, &bytes)
            .map_err(|e| format!("failed to write screenshot to {}: {e}", path.display()))?;
        return Ok(format!(
            "saved screenshot of pane {id} to {} ({width}x{height} png)\n",
            path.display()
        ));
    }

    use std::io::IsTerminal;
    if !std::io::stdout().is_terminal() {
        use std::io::Write;
        let mut stdout = std::io::stdout().lock();
        stdout
            .write_all(&bytes)
            .map_err(|e| format!("failed to write screenshot to stdout: {e}"))?;
        let _ = stdout.flush();
        Ok(String::new())
    } else {
        let path = write_exclusive_temp_file(id, &bytes)?;
        Ok(format!(
            "saved screenshot of pane {id} to {} ({width}x{height} png)\n",
            path.display()
        ))
    }
}
