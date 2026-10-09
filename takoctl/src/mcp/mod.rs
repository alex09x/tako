/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

//! Stdio Model Context Protocol (MCP) server for Tako.
//!
//! Exposes Tako's terminal control and observation capabilities (tree, split, run,
//! wait, last, find, notify, status, progress, ask) to autonomous coding agents over
//! stdio JSON-RPC 2.0. Each tool is protected by the G1 capability scope model.

pub mod capabilities;
pub mod request;
pub mod response;
pub mod server;
pub mod tools;

#[cfg(test)]
mod tests;

#[allow(unused_imports)]
pub use capabilities::{Capabilities, CapabilityScope};
pub use server::McpServer;
#[allow(unused_imports)]
pub use tools::{McpTool, all_tools};
