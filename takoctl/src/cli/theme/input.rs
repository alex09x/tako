/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use std::io::Read;

// ControlProtocol.maxRequestBytes. JSON escaping can expand config text, so
// the encoded envelope is checked separately too.
pub(super) const MAX_REQUEST_BYTES: usize = 1 << 20;

pub(super) fn read_config(reader: &mut impl Read) -> Result<String, String> {
    let mut bytes = Vec::new();
    reader
        .take((MAX_REQUEST_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("cannot read theme config: {e}"))?;
    if bytes.len() > MAX_REQUEST_BYTES {
        return Err("theme config exceeds the 1 MiB request limit".into());
    }
    String::from_utf8(bytes).map_err(|e| format!("theme config must be UTF-8: {e}"))
}

pub(super) fn load_config(path: &str) -> Result<String, String> {
    let expanded = crate::reports::expand_path(path);
    let mut file = std::fs::File::open(&expanded)
        .map_err(|e| format!("cannot read theme file '{path}': {e}"))?;
    read_config(&mut file)
}
