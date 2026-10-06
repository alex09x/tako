/*
 * Tako — Terminal Emulation Engine
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::checkpoint::{self, CheckpointError, CheckpointInfo};
use super::state::Terminal;

impl Terminal {
    /// Export the complete terminal state as a native versioned binary checkpoint.
    ///
    /// Fails rather than emitting a checkpoint this build could not read back:
    /// the invariant callers depend on is that a successful export is
    /// importable under the same version and limits. A failed export has not
    /// touched the terminal -- nothing truncated, cleared or reset.
    pub fn export_checkpoint(&self) -> Result<Vec<u8>, CheckpointError> {
        checkpoint::export(self)
    }

    /// [`Self::export_checkpoint`] with a caller-supplied byte cap. The
    /// effective limit is `min(max_bytes, checkpoint::MAX_CONTAINER_LEN)`, or the
    /// ceiling alone when `max_bytes` is 0, and it bounds the whole container
    /// including its header.
    pub fn export_checkpoint_limited(&self, max_bytes: u64) -> Result<Vec<u8>, CheckpointError> {
        checkpoint::export_limited(self, max_bytes)
    }

    /// [`Self::export_checkpoint_limited`] in a chosen container version (0 for
    /// the current one), for a peer that reads no newer. See
    /// [`checkpoint::export_version`].
    pub fn export_checkpoint_version(
        &self,
        version: u32,
        max_bytes: u64,
    ) -> Result<Vec<u8>, CheckpointError> {
        checkpoint::export_version(self, version, max_bytes)
    }

    /// How many bytes [`Self::export_checkpoint_version`] would produce.
    pub fn measure_checkpoint_version(
        &self,
        version: u32,
        max_bytes: u64,
    ) -> Result<u64, CheckpointError> {
        checkpoint::measure_version(self, version, max_bytes)
    }

    /// How many bytes [`Self::export_checkpoint`] would produce, without
    /// producing them.
    pub fn measure_checkpoint(&self) -> Result<u64, CheckpointError> {
        checkpoint::measure(self)
    }

    /// [`Self::measure_checkpoint`] bounded by a caller-supplied byte cap,
    /// mirroring [`Self::export_checkpoint_limited`].
    pub fn measure_checkpoint_limited(&self, max_bytes: u64) -> Result<u64, CheckpointError> {
        checkpoint::measure_limited(self, max_bytes)
    }

    /// The checkpoint container version this build writes.
    pub fn checkpoint_version() -> u32 {
        checkpoint::version()
    }

    /// Whether this build can import that container version.
    pub fn checkpoint_supports(version: u32) -> bool {
        checkpoint::supports(version)
    }

    /// Header and geometry of a checkpoint, without decoding it.
    pub fn inspect_checkpoint(data: &[u8]) -> Result<CheckpointInfo, CheckpointError> {
        checkpoint::inspect(data)
    }

    /// Restore the terminal state from a native checkpoint.
    ///
    /// Validates magic, format version, CRC32 checksum, dimensions, and payload integrity.
    /// Restoration is atomic: if validation or decoding fails, `self` is
    /// unmodified.
    ///
    /// The replacement is built *beside* the terminal it replaces -- `self` is
    /// not freed until the assignment -- so both are live at the peak, and the
    /// allocation budget is charged for both. A checkpoint that a fresh
    /// `Terminal` would accept can therefore be refused here, with `self`
    /// intact, rather than admitted into a process that is already holding the
    /// destination.
    pub fn import_checkpoint(&mut self, data: &[u8]) -> Result<(), CheckpointError> {
        // The destination stays live across the import, and so does the
        // container the caller handed us. What the destination costs is what it
        // has *reserved*, not what a checkpoint of it would decode to: a
        // cleared 8 MiB OSC buffer still occupies 8 MiB while reporting a
        // length of zero, and that memory is live for the whole import.
        let reserved = checkpoint::retained_cost(self).saturating_add(data.len() as u64);
        let mut restored = checkpoint::import_reserving(data, reserved)?;
        restored.set_grapheme_width_method(self.grapheme_width_method);
        *self = restored;
        Ok(())
    }

    /// Verify the integrity and version of a native checkpoint without mutating state.
    pub fn verify_checkpoint(data: &[u8]) -> bool {
        checkpoint::verify(data)
    }
}
