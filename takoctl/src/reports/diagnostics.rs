/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::fs;
use std::path::PathBuf;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use serde_json::{json, Map, Value};

use crate::cli::Options;
use crate::reports::expand_path;

pub fn reduce_path(path: &str) -> String {
    if path.is_empty() {
        return String::new();
    }
    if let Ok(home) = std::env::var("HOME") {
        if !home.is_empty() && path.starts_with(&home) {
            return format!("~{}", &path[home.len()..]);
        }
    }
    if path.starts_with("/Users/") {
        let parts: Vec<&str> = path.splitn(4, '/').collect();
        if parts.len() >= 4 {
            return format!("~/{}", parts[3]);
        } else if parts.len() == 3 {
            return "~".to_string();
        }
    }
    path.to_string()
}

pub fn redact_secrets(text: &str) -> String {
    let mut out = Vec::new();
    let mut in_private_key = false;

    for line in text.lines() {
        let reduced = reduce_path(line);
        let mut sanitized = reduced;

        // Mask complete private key blocks (BEGIN ... PRIVATE KEY ... END ... PRIVATE KEY)
        if sanitized.contains("BEGIN ") && sanitized.contains("PRIVATE KEY-----") {
            in_private_key = true;
            out.push("[REDACTED_PRIVATE_KEY]".to_string());
            continue;
        }
        if in_private_key {
            if sanitized.contains("END ") && sanitized.contains("PRIVATE KEY-----") {
                in_private_key = false;
            }
            continue;
        }
        if sanitized.contains("PRIVATE KEY-----") {
            out.push("[REDACTED_PRIVATE_KEY]".to_string());
            continue;
        }

        // Mask key=val or key: val secret patterns
        let lower = sanitized.to_lowercase();
        if lower.contains("token")
            || lower.contains("secret")
            || lower.contains("password")
            || lower.contains("api_key")
            || lower.contains("apikey")
            || lower.contains("bearer")
        {
            if let Some(pos) = sanitized.find(|c| c == '=' || c == ':') {
                let key = &sanitized[..pos];
                let delim = &sanitized[pos..=pos];
                sanitized = format!("{key}{delim} [REDACTED]");
            }
        }

        // Known token prefixes (GitHub, GitLab, Slack, AWS)
        const TOKEN_PREFIXES: &[&str] = &[
            "ghp_", "gho_", "ghu_", "ghs_", "ghr_", "glpat-", "xoxb-", "xoxp-", "xoxa-", "xoxr-",
            "xoxs-", "AKIA",
        ];
        for token_prefix in TOKEN_PREFIXES {
            while let Some(start) = sanitized.find(token_prefix) {
                let end = sanitized[start..]
                    .find(|c: char| c.is_whitespace() || c == '"' || c == '\'' || c == ',')
                    .map(|e| start + e)
                    .unwrap_or(sanitized.len());
                sanitized.replace_range(start..end, "[REDACTED_TOKEN]");
            }
        }

        out.push(sanitized);
    }
    out.join("\n")
}

pub fn collect_system_info() -> Value {
    let mut sys = Map::new();
    sys.insert("arch".into(), Value::String(std::env::consts::ARCH.into()));
    sys.insert("os".into(), Value::String(std::env::consts::OS.into()));

    // Try reading sw_vers
    if let Ok(output) = std::process::Command::new("sw_vers")
        .arg("-productVersion")
        .output()
    {
        if output.status.success() {
            let ver = String::from_utf8_lossy(&output.stdout).trim().to_string();
            sys.insert("os_version".into(), Value::String(ver));
        }
    }

    // Try reading uname
    if let Ok(output) = std::process::Command::new("uname").arg("-r").output() {
        if output.status.success() {
            let kernel = String::from_utf8_lossy(&output.stdout).trim().to_string();
            sys.insert("kernel".into(), Value::String(kernel));
        }
    }

    Value::Object(sys)
}

pub fn collect_config() -> (Option<String>, Option<String>) {
    let home = std::env::var("HOME").unwrap_or_default();
    if home.is_empty() {
        return (None, None);
    }
    let config_path = PathBuf::from(home).join(".config/tako/config");
    let display_path = reduce_path(&config_path.to_string_lossy());
    if !config_path.exists() {
        return (Some(display_path), None);
    }
    match fs::read_to_string(&config_path) {
        Ok(raw) => (Some(display_path), Some(redact_secrets(&raw))),
        Err(_) => (Some(display_path), None),
    }
}

pub fn collect_crashes() -> Vec<Value> {
    let mut reports = Vec::new();
    let home = std::env::var("HOME").unwrap_or_default();
    if home.is_empty() {
        return reports;
    }
    let diag_dir = PathBuf::from(home).join("Library/Logs/DiagnosticReports");
    if let Ok(entries) = fs::read_dir(diag_dir) {
        let mut matches: Vec<PathBuf> = entries
            .filter_map(Result::ok)
            .map(|e| e.path())
            .filter(|p| {
                p.file_name()
                    .and_then(|n| n.to_str())
                    .map(|s| s.starts_with("Tako") || s.starts_with("takoctl"))
                    .unwrap_or(false)
            })
            .collect();
        matches.sort();
        for p in matches.into_iter().rev().take(5) {
            let name = p
                .file_name()
                .unwrap_or_default()
                .to_string_lossy()
                .to_string();
            let preview = fs::read_to_string(&p)
                .ok()
                .map(|s| {
                    let top = s.lines().take(20).collect::<Vec<_>>().join("\n");
                    redact_secrets(&top)
                })
                .unwrap_or_default();
            reports.push(json!({
                "filename": name,
                "preview": preview,
            }));
        }
    }
    reports
}

pub fn run_benchmark() -> Value {
    let iterations: usize = 50_000;
    let start = Instant::now();
    let mut sink: u64 = 0;
    for i in 0..iterations {
        sink = sink.wrapping_add((i as u64) ^ 0xa5a5_5a5a);
    }
    let elapsed = start.elapsed();
    let secs = elapsed.as_secs_f64();
    let ops_per_sec = (iterations as f64) / secs.max(0.000_001);
    json!({
        "iterations": iterations,
        "elapsed_seconds": secs,
        "ops_per_second": ops_per_sec,
        "sink": sink
    })
}

pub fn build_report(opts: &Options, app_result: Option<&Value>) -> Value {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    let (cfg_path, cfg_content) = collect_config();
    let crashes = collect_crashes();
    let sys_info = collect_system_info();
    let benchmark = if opts
        .args
        .get("benchmark")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        Some(run_benchmark())
    } else {
        None
    };

    let mut report = Map::new();
    report.insert("timestamp_epoch".into(), Value::from(now));
    report.insert(
        "cli_version".into(),
        Value::String(env!("CARGO_PKG_VERSION").into()),
    );
    report.insert("system".into(), sys_info);

    if let Some(p) = cfg_path {
        report.insert("config_path".into(), Value::String(p));
    }
    if let Some(c) = cfg_content {
        report.insert("config_redacted".into(), Value::String(c));
    }
    report.insert("crashes".into(), Value::Array(crashes));
    if let Some(bm) = benchmark {
        report.insert("benchmark".into(), bm);
    }

    if let Some(app) = app_result {
        report.insert("tako_app_reachable".into(), Value::Bool(true));
        report.insert("app".into(), app.clone());
    } else {
        report.insert("tako_app_reachable".into(), Value::Bool(false));
    }

    Value::Object(report)
}

pub fn handle_diagnose(opts: &Options, app_result: Option<&Value>) -> Result<String, String> {
    let report = build_report(opts, app_result);
    let json_text = serde_json::to_string_pretty(&report)
        .map_err(|e| format!("failed to format diagnostics JSON: {e}"))?;

    let to_stdout = opts
        .args
        .get("stdout")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || (opts.json && opts.args.get("out").is_none());
    if to_stdout {
        return Ok(format!("{json_text}\n"));
    }

    let default_out = format!(
        "tako-diagnostics-{}.json",
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0)
    );
    let out_path = opts
        .args
        .get("out")
        .and_then(Value::as_str)
        .map(expand_path)
        .unwrap_or(default_out);

    let target_path = std::path::Path::new(&out_path);
    let existed = target_path.exists();

    #[cfg(unix)]
    {
        use std::fs::OpenOptions;
        use std::io::Write;
        use std::os::unix::fs::OpenOptionsExt;

        let mut file_opts = OpenOptions::new();
        file_opts.write(true).create(true).truncate(true);
        if !existed {
            file_opts.mode(0o600);
        }
        let mut f = file_opts
            .open(&out_path)
            .map_err(|e| format!("failed to write diagnostics to {out_path}: {e}"))?;
        f.write_all(json_text.as_bytes())
            .map_err(|e| format!("failed to write diagnostics to {out_path}: {e}"))?;
    }
    #[cfg(not(unix))]
    {
        fs::write(&out_path, &json_text)
            .map_err(|e| format!("failed to write diagnostics to {out_path}: {e}"))?;
    }

    let terminal_included = opts
        .args
        .get("include_terminal")
        .and_then(Value::as_bool)
        .unwrap_or(false);

    let notice = if terminal_included {
        "(terminal contents included via --include-terminal)"
    } else {
        "(contains NO terminal contents)"
    };

    Ok(format!(
        "Diagnostics written to {out_path}.\nThis bundle contains version, system, and redacted configuration data {notice}.\n"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_reduce_path() {
        assert_eq!(reduce_path(""), "");
        assert_eq!(reduce_path("/Users/alice/projects/tako"), "~/projects/tako");
        assert_eq!(reduce_path("/Users/bob"), "~");
        assert_eq!(reduce_path("/tmp/scratch"), "/tmp/scratch");
    }

    #[test]
    fn test_redact_secrets() {
        let input = "api_key: abc123xyz789\ntoken = supersecret\nnormal_line = true\nghp_123456789012345678901234567890\noauth = gho_abcdef12345678901234567890\nuser_auth: ghu_99887766554433221100";
        let redacted = redact_secrets(input);
        assert!(!redacted.contains("abc123xyz789"));
        assert!(!redacted.contains("supersecret"));
        assert!(!redacted.contains("ghp_123456789012345678901234567890"));
        assert!(!redacted.contains("gho_abcdef12345678901234567890"));
        assert!(!redacted.contains("ghu_99887766554433221100"));
        assert!(redacted.contains("normal_line = true"));
        assert!(redacted.contains("[REDACTED]"));
        assert!(redacted.contains("[REDACTED_TOKEN]"));
    }

    #[test]
    fn test_build_report_structure() {
        let opts = crate::cli::parse(&["diagnose".into(), "--stdout".into(), "--benchmark".into()])
            .unwrap();
        let report = build_report(&opts, None);
        assert_eq!(report["tako_app_reachable"], false);
        assert!(report["system"]["arch"].is_string());
        assert!(report["benchmark"]["iterations"].is_number());
    }

    #[test]
    fn test_diagnose_stdout() {
        let opts = crate::cli::parse(&["diagnose".into(), "--stdout".into()]).unwrap();
        let out = handle_diagnose(&opts, None).unwrap();
        let val: Value = serde_json::from_str(&out).unwrap();
        assert!(val["cli_version"].is_string());
    }

    #[test]
    fn test_redact_multiline_pem_private_key() {
        let input = "before = 1\n-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA0m...\n...base64_data...\n-----END RSA PRIVATE KEY-----\nafter = 2";
        let redacted = redact_secrets(input);
        assert!(!redacted.contains("MIIEowIBAAKCAQEA0m"));
        assert!(!redacted.contains("base64_data"));
        assert!(!redacted.contains("RSA PRIVATE KEY"));
        assert!(redacted.contains("[REDACTED_PRIVATE_KEY]"));
        assert!(redacted.contains("before = 1"));
        assert!(redacted.contains("after = 2"));
    }

    #[cfg(unix)]
    #[test]
    fn test_diagnose_file_permissions() {
        use std::os::unix::fs::PermissionsExt;
        let tmp_dir = std::env::temp_dir();
        let out_file = tmp_dir.join(format!(
            "test-diag-{}.json",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let opts = crate::cli::parse(&[
            "diagnose".into(),
            "--out".into(),
            out_file.to_str().unwrap().into(),
        ])
        .unwrap();
        handle_diagnose(&opts, None).unwrap();
        let meta = std::fs::metadata(&out_file).unwrap();
        let mode = meta.permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let _ = std::fs::remove_file(out_file);
    }
}
