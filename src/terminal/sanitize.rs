/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::time::{Duration, Instant};

use super::state::Terminal;

impl Terminal {
    /// Handle OSC 8 (`ESC ] 8 ; params ; uri ST`): open or close a hyperlink span.
    pub(crate) fn osc8_hyperlink(&mut self, params: &[&[u8]]) {
        let uri = params.get(2).copied().unwrap_or(b"");
        if uri.is_empty() {
            self.current_hyperlink = None;
            return;
        }
        let uri = String::from_utf8_lossy(uri).into_owned();

        let explicit_id = params.get(1).and_then(|param_str| {
            let param_str = String::from_utf8_lossy(param_str);
            param_str
                .split(':')
                .find_map(|kv| kv.strip_prefix("id="))
                .filter(|id| !id.is_empty())
                .map(str::to_owned)
        });

        let id = match explicit_id {
            Some(explicit_id) => *self.hyperlink_ids.entry(explicit_id).or_insert_with(|| {
                let new_id = self.hyperlinks.len() as u32 + 1;
                self.hyperlinks.push(uri.clone());
                new_id
            }),
            None => {
                let new_id = self.hyperlinks.len() as u32 + 1;
                self.hyperlinks.push(uri);
                new_id
            }
        };

        self.current_hyperlink = Some(id);
    }

    pub(crate) fn normalize_status_string(raw: &str) -> Option<String> {
        let trimmed = raw.trim().to_ascii_lowercase();
        match trimmed.as_str() {
            "idle" => Some("idle".into()),
            "running" => Some("running".into()),
            "working" | "thinking" => Some("working".into()),
            "waiting_for_input" => Some("waiting_for_input".into()),
            "needs_approval" => Some("needs_approval".into()),
            "done" => Some("done".into()),
            "error" => Some("error".into()),
            "disconnected" => Some("disconnected".into()),
            "unknown" => Some("unknown".into()),
            "clear" => Some("clear".into()),
            _ => None,
        }
    }

    /// Rate-limits desktop notifications to at most 10 per second per terminal instance using a sliding window (Track G4).
    pub(crate) fn allow_notification(&mut self) -> bool {
        const MAX_NOTIFICATIONS_PER_SEC: usize = 10;
        const WINDOW_DURATION: Duration = Duration::from_secs(1);
        let now = Instant::now();
        self.notification_timestamps
            .retain(|&ts| now.duration_since(ts) < WINDOW_DURATION);
        if self.notification_timestamps.len() < MAX_NOTIFICATIONS_PER_SEC {
            self.notification_timestamps.push_back(now);
            true
        } else {
            false
        }
    }

    /// Sanitizes title strings (max 512 chars, strips C0/C1 control codes except tab) (Track G4).
    pub fn sanitize_title(raw: &str) -> String {
        let mut out = String::new();
        let mut count = 0usize;
        for ch in raw.chars().take(4096) {
            if count >= 512 {
                break;
            }
            if ch == '\t' || (!ch.is_control() && !('\u{0080}'..='\u{009F}').contains(&ch)) {
                out.push(ch);
                count += 1;
            }
        }
        out
    }

    /// Sanitizes notification text, stripping C0/C1 controls except whitespace, bounded by max_chars (Track G4).
    pub fn sanitize_notification_text(raw: &str, max_chars: usize) -> String {
        let mut out = String::new();
        let mut count = 0usize;
        let scan_limit = max_chars.saturating_mul(8).max(4096);
        for ch in raw.chars().take(scan_limit) {
            if count >= max_chars {
                break;
            }
            if ch == '\t'
                || ch == '\n'
                || (!ch.is_control() && !('\u{0080}'..='\u{009F}').contains(&ch))
            {
                out.push(ch);
                count += 1;
            }
        }
        out
    }

    pub fn sanitize_status_text(raw: &str) -> Option<String> {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return None;
        }
        let mut out = String::new();
        let mut count = 0usize;
        for ch in trimmed.chars().take(2048) {
            if count >= 256 {
                break;
            }
            if !ch.is_control() && !('\u{0080}'..='\u{009F}').contains(&ch) {
                out.push(ch);
                count += 1;
            }
        }
        let final_trimmed = out.trim();
        if final_trimmed.is_empty() {
            None
        } else {
            Some(final_trimmed.to_string())
        }
    }
}
