/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

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
}
