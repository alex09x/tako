/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use serde_json::{Map, Value};

use crate::reports::expand_path;

pub fn parse(
    cmd: &str,
    args: &mut Map<String, Value>,
    positional: &mut Vec<String>,
) -> Result<Option<()>, String> {
    if cmd != "diagnose" {
        return Ok(None);
    }

    if !positional.is_empty() {
        let out_path = positional.remove(0);
        args.insert("out".into(), Value::String(expand_path(&out_path)));
    }

    if !positional.is_empty() {
        return Err(format!("unexpected argument {}", positional[0]));
    }

    Ok(Some(()))
}
