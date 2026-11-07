/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use base64::Engine as _;
use base64::engine::{DecodePaddingMode, GeneralPurpose, GeneralPurposeConfig};

use super::{
    MAX_APP_BYTES, MAX_ID_BYTES, MAX_ID_DEPTH, MAX_ID_SEGMENT_BYTES, MAX_KEY_BYTES,
    MAX_MSG_DECODED_BYTES, MAX_MSG_ENCODED_BYTES, MAX_TITLE_DECODED_BYTES, MAX_TITLE_ENCODED_BYTES,
    ProgramStatusBlockedKind, ProgramStatusState,
};

const BASE64_INDIFFERENT: GeneralPurpose = GeneralPurpose::new(
    &base64::alphabet::STANDARD,
    GeneralPurposeConfig::new().with_decode_padding_mode(DecodePaddingMode::Indifferent),
);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum ParsedAction {
    Clear {
        id: String,
    },
    Upsert {
        id: String,
        state: ProgramStatusState,
        kind: Option<ProgramStatusBlockedKind>,
        progress: Option<u8>,
        app: Option<String>,
        title: Option<String>,
        msg: Option<String>,
    },
}

#[inline]
pub(super) fn trim_ascii(bytes: &[u8]) -> &[u8] {
    bytes.trim_ascii()
}

#[inline]
fn is_osc7501_value_byte(b: &u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b',' | b'+' | b'/' | b'=' | b'-')
}

#[inline]
fn is_id_or_app_byte(b: &u8) -> bool {
    b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b'+' | b'-')
}

#[inline]
fn is_forbidden_control_char(c: char) -> bool {
    matches!(c as u32, 0x0000..=0x001F | 0x007F | 0x0080..=0x009F)
}

#[inline]
fn is_disarmed_formatting_char(c: char) -> bool {
    matches!(
        c as u32,
        0x061C
            | 0x200E
            | 0x200F
            | 0x2028..=0x202E
            | 0x2066..=0x2069
            | 0xFEFF
            | 0xFFF9..=0xFFFB
            | 0xE0000..=0xE007F
    )
}

fn decode_and_sanitize_text(
    encoded: &[u8],
    max_encoded: usize,
    max_decoded: usize,
) -> Option<Option<String>> {
    if encoded.len() > max_encoded {
        return None;
    }
    if encoded.is_empty() {
        return Some(None);
    }
    if !encoded
        .iter()
        .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'='))
    {
        return None;
    }
    let decoded = BASE64_INDIFFERENT.decode(encoded).ok()?;
    if decoded.len() > max_decoded {
        return None;
    }
    let text = std::str::from_utf8(&decoded).ok()?;
    if text.chars().any(is_forbidden_control_char) {
        return None;
    }
    let sanitized: String = text
        .chars()
        .filter(|&c| !is_disarmed_formatting_char(c))
        .collect();
    if sanitized.is_empty() {
        Some(None)
    } else {
        Some(Some(sanitized))
    }
}

fn validate_id(raw: &[u8]) -> Option<String> {
    if raw.is_empty() || raw.len() > MAX_ID_BYTES {
        return None;
    }
    let mut depth = 0usize;
    for seg in raw.split(|&b| b == b'/') {
        depth += 1;
        if depth > MAX_ID_DEPTH {
            return None;
        }
        if seg.is_empty() || seg.len() > MAX_ID_SEGMENT_BYTES {
            return None;
        }
        if !seg.iter().all(is_id_or_app_byte) {
            return None;
        }
    }
    std::str::from_utf8(raw).ok().map(String::from)
}

pub(super) fn parse_report(body: &[u8]) -> Option<ParsedAction> {
    let mut raw_state: Option<&[u8]> = None;
    let mut id = String::new();
    let mut kind: Option<ProgramStatusBlockedKind> = None;
    let mut progress: Option<u8> = None;
    let mut app: Option<String> = None;
    let mut title: Option<String> = None;
    let mut msg: Option<String> = None;

    for raw_pair in body.split(|&b| b == b':') {
        let Some(eq_idx) = raw_pair.iter().position(|&b| b == b'=') else {
            continue;
        };
        let key = trim_ascii(&raw_pair[..eq_idx]);
        let val = trim_ascii(&raw_pair[eq_idx + 1..]);
        if key.is_empty() {
            continue;
        }
        if key.len() > MAX_KEY_BYTES {
            return None;
        }
        if !key.iter().all(|b| b.is_ascii_lowercase()) {
            continue;
        }

        match key {
            b"state" => {
                raw_state = Some(val);
            }
            b"id" => {
                id = validate_id(val)?;
            }
            b"msg" => {
                msg = decode_and_sanitize_text(val, MAX_MSG_ENCODED_BYTES, MAX_MSG_DECODED_BYTES)?;
            }
            b"title" => {
                title = decode_and_sanitize_text(
                    val,
                    MAX_TITLE_ENCODED_BYTES,
                    MAX_TITLE_DECODED_BYTES,
                )?;
            }
            b"app" => {
                if val.len() > MAX_APP_BYTES {
                    return None;
                }
                if !val.is_empty() && val.iter().all(is_id_or_app_byte) {
                    app = std::str::from_utf8(val).ok().map(String::from);
                } else {
                    app = None;
                }
            }
            b"kind" => {
                kind = match val {
                    b"permission" => Some(ProgramStatusBlockedKind::Permission),
                    b"question" => Some(ProgramStatusBlockedKind::Question),
                    b"auth" => Some(ProgramStatusBlockedKind::Auth),
                    _ => None,
                };
            }
            b"progress" => {
                progress = if !val.is_empty() && val.iter().all(|b| b.is_ascii_digit()) {
                    std::str::from_utf8(val)
                        .ok()
                        .and_then(|s| s.parse::<u8>().ok())
                        .filter(|&n| n <= 100)
                } else {
                    None
                };
            }
            _ => {
                if !val.iter().all(is_osc7501_value_byte) {
                    continue;
                }
            }
        }
    }

    let state_bytes = raw_state?;
    if state_bytes == b"clear" {
        return Some(ParsedAction::Clear { id });
    }
    let state = match state_bytes {
        b"idle" => ProgramStatusState::Idle,
        b"working" => ProgramStatusState::Working,
        b"done" => ProgramStatusState::Done,
        b"blocked" => ProgramStatusState::Blocked,
        b"error" => ProgramStatusState::Error,
        _ => return None,
    };

    let effective_kind = if state == ProgramStatusState::Blocked {
        kind
    } else {
        None
    };
    let effective_progress =
        if state == ProgramStatusState::Working || state == ProgramStatusState::Blocked {
            progress
        } else {
            None
        };

    Some(ParsedAction::Upsert {
        id,
        state,
        kind: effective_kind,
        progress: effective_progress,
        app,
        title,
        msg,
    })
}
