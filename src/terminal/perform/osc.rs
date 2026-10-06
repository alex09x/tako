/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::super::commands;
use super::super::events::TerminalEvent;
use super::super::state::Terminal;
use super::super::types::ClipboardPolicy;

impl Terminal {
    pub(crate) fn perform_osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
        if params.is_empty() {
            return;
        }

        if params.len() >= 2 && (params[0] == b"0" || params[0] == b"2") {
            let slice = &params[1][..params[1].len().min(4096)];
            let raw = String::from_utf8_lossy(slice);
            self.title = Self::sanitize_title(&raw);
            self.events
                .push(TerminalEvent::TitleChanged(self.title.clone()));
            return;
        }

        if params[0] == b"8" {
            self.osc8_hyperlink(params);
            return;
        }

        if self.handle_osc_palette(params, bell_terminated) {
            return;
        }

        if params[0] == b"52" {
            if self.clipboard_policy == ClipboardPolicy::Disabled {
                return;
            }
            if let Some(payload) = params.get(2) {
                if payload == b"?" {
                    if self.clipboard_policy == ClipboardPolicy::ReadWrite {
                        self.events.push(TerminalEvent::ClipboardQuery);
                    }
                } else {
                    const MAX_CLIPBOARD_BYTES: usize = 1024 * 1024;
                    let non_ws_count = payload.iter().filter(|b| !b.is_ascii_whitespace()).count();
                    if payload.len() <= 2 * 1024 * 1024
                        && (non_ws_count.saturating_sub(2) * 3) / 4 <= MAX_CLIPBOARD_BYTES
                    {
                        use base64::Engine as _;
                        if let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(payload)
                            && bytes.len() <= MAX_CLIPBOARD_BYTES
                        {
                            let text = String::from_utf8_lossy(&bytes).into_owned();
                            self.events.push(TerminalEvent::ClipboardSet(text));
                        }
                    }
                }
            }
            return;
        }

        if params[0] == b"7" {
            if let Some(url) = params.get(1)
                && url.len() <= commands::MAX_CWD_BYTES
            {
                let url_str = String::from_utf8_lossy(url).into_owned();
                self.last_cwd = Some(url_str.clone());
                self.events.push(TerminalEvent::PwdChanged(url_str));
            }
            return;
        }

        if params[0] == b"9" && params.get(1).map(|p| p.as_ref()) == Some(b"4".as_ref()) {
            let state = params
                .get(2)
                .and_then(|p| String::from_utf8_lossy(p).parse::<u8>().ok())
                .unwrap_or(0);
            let value = params
                .get(3)
                .and_then(|p| String::from_utf8_lossy(p).parse::<u8>().ok())
                .map(|v| v.min(100));
            self.events.push(TerminalEvent::Progress { state, value });
            return;
        }

        if params[0] == b"9" && params.get(1).map(|p| p.as_ref()) == Some(b"5".as_ref()) {
            let raw_status = params
                .get(2)
                .map(|p| {
                    let slice = &p[..p.len().min(128)];
                    String::from_utf8_lossy(slice)
                })
                .unwrap_or_default();
            if raw_status.is_empty() || raw_status.eq_ignore_ascii_case("clear") {
                self.events.push(TerminalEvent::StatusClear);
            } else if let Some(status) = Self::normalize_status_string(&raw_status) {
                if status == "clear" {
                    self.events.push(TerminalEvent::StatusClear);
                } else {
                    let text = if params.len() > 3 {
                        let joined = params[3..]
                            .iter()
                            .take(16)
                            .map(|p| {
                                let slice = &p[..p.len().min(1024)];
                                String::from_utf8_lossy(slice)
                            })
                            .collect::<Vec<_>>()
                            .join(";");
                        Self::sanitize_status_text(&joined)
                    } else {
                        None
                    };
                    self.events.push(TerminalEvent::StatusSet { status, text });
                }
            }
            return;
        }

        if params[0] == b"9" {
            if let Some(body) = params.get(1)
                && self.allow_notification()
            {
                let slice = &body[..body.len().min(8192)];
                let raw_body = String::from_utf8_lossy(slice);
                let clean_body = Self::sanitize_notification_text(&raw_body, 1024);
                self.events.push(TerminalEvent::Notification {
                    title: String::new(),
                    body: clean_body,
                });
            }
            return;
        }

        if params[0] == b"777" {
            if params.get(1).map(|p| p.as_ref()) == Some(b"notify".as_ref())
                && self.allow_notification()
            {
                let raw_title = params
                    .get(2)
                    .map(|p| {
                        let slice = &p[..p.len().min(1024)];
                        String::from_utf8_lossy(slice)
                    })
                    .unwrap_or_default();
                let raw_body = params
                    .get(3)
                    .map(|p| {
                        let slice = &p[..p.len().min(8192)];
                        String::from_utf8_lossy(slice)
                    })
                    .unwrap_or_default();
                let title = Self::sanitize_notification_text(&raw_title, 128);
                let body = Self::sanitize_notification_text(&raw_body, 1024);
                self.events
                    .push(TerminalEvent::Notification { title, body });
            }
            return;
        }

        if params[0] == b"99" {
            self.handle_osc_99(params, bell_terminated);
            return;
        }

        if params[0] == b"133" {
            self.handle_osc_133(params);
            return;
        }

        if params[0] == b"1337" {
            self.handle_osc_1337(params);
            return;
        }

        if params[0] == b"3008" {
            self.handle_osc_3008(params);
        }
    }
}
