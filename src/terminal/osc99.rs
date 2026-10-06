/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::events::TerminalEvent;
use super::state::Terminal;
use super::types::InFlightOsc99;

impl Terminal {
    pub(crate) fn handle_osc_99(&mut self, params: &[&[u8]], bell_terminated: bool) {
        if params.len() <= 1 {
            return;
        }

        const MAX_OSC99_METADATA_BYTES: usize = 2048;
        const MAX_OSC99_CHUNK_RAW_BYTES: usize = 8192;

        let (metadata_raw, payload_raw) = if params.len() >= 3 {
            let meta = params[1];
            if meta.len() > MAX_OSC99_METADATA_BYTES {
                return;
            }
            let total_payload_len: usize = params[2..]
                .iter()
                .map(|p| p.len())
                .sum::<usize>()
                .saturating_add(params.len().saturating_sub(3));
            if total_payload_len > MAX_OSC99_CHUNK_RAW_BYTES {
                return;
            }
            let payload = if params.len() == 3 {
                params[2].to_vec()
            } else {
                let mut joined = Vec::with_capacity(total_payload_len);
                for (idx, part) in params[2..].iter().enumerate() {
                    if idx > 0 {
                        joined.push(b';');
                    }
                    joined.extend_from_slice(part);
                }
                joined
            };
            (meta, payload)
        } else {
            if params[1].contains(&b'=') {
                if params[1].len() > MAX_OSC99_METADATA_BYTES {
                    return;
                }
                (params[1], Vec::new())
            } else {
                if params[1].len() > MAX_OSC99_CHUNK_RAW_BYTES {
                    return;
                }
                (b"".as_ref(), params[1].to_vec())
            }
        };

        let metadata_str = String::from_utf8_lossy(metadata_raw);
        let mut id: Option<String> = None;
        let mut done: Option<u8> = None;
        let mut payload_type: Option<String> = None;
        let mut is_base64: bool = false;
        let mut urgency: Option<u8> = None;
        let mut actions_str: Option<String> = None;
        let mut report_close_opt: Option<u8> = None;
        let mut timeout_ms: Option<u64> = None;
        let mut occasion: Option<String> = None;
        let mut app_name_b64: Option<String> = None;

        for part in metadata_str.split(':') {
            if let Some((k, v)) = part.split_once('=') {
                match k.trim() {
                    "i" => {
                        let clean: String = v
                            .chars()
                            .filter(|c| {
                                c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '+' | '.')
                            })
                            .take(128)
                            .collect();
                        if !clean.is_empty() {
                            id = Some(clean);
                        }
                    }
                    "d" => done = v.trim().parse::<u8>().ok(),
                    "p" => payload_type = Some(v.trim().to_ascii_lowercase()),
                    "e" => is_base64 = v.trim() == "1",
                    "u" => urgency = v.trim().parse::<u8>().ok(),
                    "a" => actions_str = Some(v.trim().to_string()),
                    "c" => report_close_opt = v.trim().parse::<u8>().ok(),
                    "w" => {
                        if let Ok(w_val) = v.trim().parse::<i64>()
                            && w_val > 0
                        {
                            timeout_ms = Some(w_val as u64);
                        }
                    }
                    "o" => occasion = Some(v.trim().to_ascii_lowercase()),
                    "f" => app_name_b64 = Some(v.trim().to_string()),
                    _ => {}
                }
            }
        }

        let p_type = payload_type.as_deref().unwrap_or("title");

        // 1. Query capabilities: p=?
        if p_type == "?" {
            let id_str = id.as_deref().unwrap_or("0");
            let terminator = if bell_terminated { "\x07" } else { "\x1b\\" };
            let reply = format!(
                "\x1b]99;i={}:p=?;a=focus,report:c=1:o=always,unfocused,invisible:p=title,body,buttons,close:u=0,1,2{}",
                id_str, terminator
            );
            self.response.push_str(&reply);
            return;
        }

        // 2. Query alive: p=alive
        if p_type == "alive" {
            let id_str = id.as_deref().unwrap_or("0");
            let terminator = if bell_terminated { "\x07" } else { "\x1b\\" };
            let reply = format!("\x1b]99;i={}:p=alive;{}", id_str, terminator);
            self.response.push_str(&reply);
            return;
        }

        // 3. Close notification: p=close
        if p_type == "close" {
            if let Some(ref close_id) = id {
                self.events.push(TerminalEvent::NotificationClose {
                    id: close_id.clone(),
                    report_close: report_close_opt == Some(1),
                });
                self.in_flight_osc99.remove(close_id);
            }
            return;
        }

        // 4. Decode payload text with strict pre-decode size bounds
        let payload_bytes = if is_base64 {
            use base64::Engine as _;
            base64::engine::general_purpose::STANDARD
                .decode(&payload_raw)
                .unwrap_or_default()
        } else {
            payload_raw
        };
        let payload_text = String::from_utf8_lossy(&payload_bytes).into_owned();

        // 5. Decode application name if provided (bounded)
        let app_name = app_name_b64.and_then(|b64| {
            if b64.len() > 256 {
                return None;
            }
            use base64::Engine as _;
            base64::engine::general_purpose::STANDARD
                .decode(b64.as_bytes())
                .ok()
                .map(|b| {
                    let s = String::from_utf8_lossy(&b).into_owned();
                    Self::sanitize_notification_text(&s, 64)
                })
        });

        // 6. Find or create in-flight record (capped to at most 16 concurrent in-flight records)
        const MAX_IN_FLIGHT_OSC99: usize = 16;
        let mut entry = if let Some(ref id_str) = id {
            if self.in_flight_osc99.len() >= MAX_IN_FLIGHT_OSC99
                && !self.in_flight_osc99.contains_key(id_str)
                && let Some(k) = self.in_flight_osc99.keys().next().cloned()
            {
                self.in_flight_osc99.remove(&k);
            }
            self.in_flight_osc99
                .remove(id_str)
                .unwrap_or_else(|| InFlightOsc99 {
                    id: Some(id_str.clone()),
                    focus: true,
                    urgency: 1,
                    ..Default::default()
                })
        } else {
            self.unidentified_osc99
                .take()
                .unwrap_or_else(|| InFlightOsc99 {
                    id: None,
                    focus: true,
                    urgency: 1,
                    ..Default::default()
                })
        };

        if let Some(app) = app_name {
            entry.app_name = Some(app);
        }
        if let Some(u) = urgency {
            entry.urgency = u.min(2);
        }
        if let Some(t) = timeout_ms {
            entry.timeout_ms = Some(t);
        }
        if let Some(c) = report_close_opt {
            entry.report_close = c == 1;
        }
        if let Some(ref o) = occasion {
            entry.only_when_unfocused = o == "unfocused" || o == "invisible";
        }
        if let Some(ref acts) = actions_str {
            for act in acts.split(',') {
                match act.trim() {
                    "report" => entry.report_activation = true,
                    "-report" => entry.report_activation = false,
                    "focus" => entry.focus = true,
                    "-focus" => entry.focus = false,
                    _ => {}
                }
            }
        }

        const MAX_NOTIFICATION_TITLE_CHARS: usize = 128;
        const MAX_NOTIFICATION_BODY_CHARS: usize = 1024;

        match p_type {
            "body" => {
                let current_chars = entry.body.chars().count();
                if current_chars < MAX_NOTIFICATION_BODY_CHARS {
                    let remaining = MAX_NOTIFICATION_BODY_CHARS - current_chars;
                    let sanitized = Self::sanitize_notification_text(&payload_text, remaining);
                    entry.body.push_str(&sanitized);
                }
            }
            "buttons" => {
                if entry.actions.len() < 8 {
                    for btn in payload_text.split('\u{2028}') {
                        if entry.actions.len() >= 8 {
                            break;
                        }
                        let trimmed = btn.trim();
                        if !trimmed.is_empty() {
                            let sanitized = Self::sanitize_notification_text(trimmed, 64);
                            if !sanitized.is_empty() {
                                entry.actions.push(sanitized);
                            }
                        }
                    }
                }
            }
            _ => {
                let current_chars = entry.title.chars().count();
                if current_chars < MAX_NOTIFICATION_TITLE_CHARS {
                    let remaining = MAX_NOTIFICATION_TITLE_CHARS - current_chars;
                    let sanitized = Self::sanitize_notification_text(&payload_text, remaining);
                    entry.title.push_str(&sanitized);
                }
            }
        }

        let is_done = done.unwrap_or(1) != 0;
        if is_done {
            let mut title = entry.title;
            let mut body = entry.body;
            if title.is_empty() && !body.is_empty() {
                title = body;
                body = String::new();
            }
            if (!title.is_empty() || !body.is_empty()) && self.allow_notification() {
                let title = Self::sanitize_notification_text(&title, 128);
                let body = Self::sanitize_notification_text(&body, 1024);
                self.events.push(TerminalEvent::StructuredNotification {
                    id: entry.id,
                    title,
                    body,
                    app_name: entry.app_name,
                    urgency: entry.urgency,
                    actions: entry.actions,
                    report_activation: entry.report_activation,
                    focus: entry.focus,
                    report_close: entry.report_close,
                    timeout_ms: entry.timeout_ms,
                    only_when_unfocused: entry.only_when_unfocused,
                });
            }
        } else if let Some(ref id_str) = id {
            self.in_flight_osc99.insert(id_str.clone(), entry);
        } else {
            self.unidentified_osc99 = Some(entry);
        }
    }
}
