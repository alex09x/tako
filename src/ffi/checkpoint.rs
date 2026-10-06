/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::core::{TakoCore, lock_recover};
use super::query_types::{FfiCheckpointInfo, TakoCheckpointError};
use crate::terminal::Terminal;

#[uniffi::export]
impl TakoCore {
    /// Export the terminal state as a native versioned binary checkpoint.
    pub fn checkpoint(&self) -> Vec<u8> {
        let terminal = lock_recover(&self.inner);
        terminal.export_checkpoint().unwrap_or_default()
    }

    /// Restore the terminal state from a native checkpoint.
    /// Returns true on success, false if the payload is invalid or corrupted.
    pub fn restore(&self, bytes: Vec<u8>) -> bool {
        self.checkpoint_import(bytes).is_ok()
    }

    /// Verify the integrity and version of a native checkpoint payload.
    pub fn verify_checkpoint(&self, bytes: Vec<u8>) -> bool {
        Terminal::verify_checkpoint(&bytes)
    }

    /// The checkpoint container version this build writes.
    pub fn checkpoint_version(&self) -> u32 {
        Terminal::checkpoint_version()
    }

    /// Whether this build can import that container version.
    pub fn checkpoint_supports(&self, version: u32) -> bool {
        Terminal::checkpoint_supports(version)
    }

    /// Export bounded by a caller-supplied byte cap.
    pub fn checkpoint_export(
        &self,
        flags: u32,
        max_bytes: u64,
    ) -> Result<Vec<u8>, TakoCheckpointError> {
        if flags != 0 {
            return Err(TakoCheckpointError::Corrupt {
                reason: format!("unknown export flags {flags}"),
            });
        }
        let terminal = lock_recover(&self.inner);
        Ok(terminal.export_checkpoint_limited(max_bytes)?)
    }

    /// `checkpoint_export` in a chosen container version.
    pub fn checkpoint_export_version(
        &self,
        version: u32,
        max_bytes: u64,
    ) -> Result<Vec<u8>, TakoCheckpointError> {
        let terminal = lock_recover(&self.inner);
        Ok(terminal.export_checkpoint_version(version, max_bytes)?)
    }

    /// Replace the terminal from a checkpoint, atomically.
    pub fn checkpoint_import(&self, blob: Vec<u8>) -> Result<(), TakoCheckpointError> {
        if blob.is_empty() {
            return Err(TakoCheckpointError::NullArgument);
        }
        let mut engine = lock_recover(&self.inner);
        let mut delta = lock_recover(&self.delta);
        engine.terminal.import_checkpoint(&blob)?;
        engine.epoch = engine.epoch.wrapping_add(1);
        delta.reset_pending = true;
        Ok(())
    }

    /// A checkpoint's version and geometry, without committing to importing it.
    pub fn checkpoint_inspect(
        &self,
        blob: Vec<u8>,
    ) -> Result<FfiCheckpointInfo, TakoCheckpointError> {
        if blob.is_empty() {
            return Err(TakoCheckpointError::NullArgument);
        }
        let info = Terminal::inspect_checkpoint(&blob)?;
        Ok(FfiCheckpointInfo {
            version: info.version,
            flags: info.flags,
            cols: info.cols,
            rows: info.rows,
            payload_len: info.payload_len,
        })
    }
}
