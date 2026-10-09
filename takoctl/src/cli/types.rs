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

#[derive(Debug, Clone)]
pub struct Options {
    pub cmd: String,
    pub args: Map<String, Value>,
    pub json: bool,
    pub socket: Option<String>,
    pub bundle_id: String,
    pub bundle_id_explicit: bool,
    pub client: Option<String>,
    pub token: Option<String>,
    pub scopes: Option<Vec<String>>,
}
