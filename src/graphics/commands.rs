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
use base64::engine::general_purpose::STANDARD as BASE64;

use super::dimensions::png_dimensions;
use super::state::GraphicsState;
use super::types::{
    ChunkKey, GraphicsCommand, GraphicsResponse, ImageFormat, PendingTransfer, Placement,
    StoredImage, parse_control_data,
};

impl GraphicsState {
    /// Handle one APC graphics command.
    ///
    /// `control_data` is the text between `ESC _ G` and `;`, `payload` the
    /// bytes between `;` and `ESC \`.
    pub fn handle(&mut self, control_data: &str, payload: &[u8]) -> GraphicsResponse {
        self.last_reply = None;
        let cmd = parse_control_data(control_data);

        let action = match (cmd.get('a'), cmd.get_char('a')) {
            (Some(_), None) => {
                return GraphicsResponse::Error("invalid action key 'a'".to_string());
            }
            (Some(_), Some(ch)) => ch,
            (None, _) => 't', // Kitty protocol default action is 't' (transmit)
        };

        let resp = match action {
            't' => self.transmit(&cmd, payload, false),
            'T' => self.transmit(&cmd, payload, true),
            'p' => self.display_stored(&cmd),
            'd' => self.delete(&cmd),
            'q' => self.query(&cmd, payload),
            other => GraphicsResponse::Error(format!("unsupported action a={other}")),
        };

        if cmd.get_u32('q') == Some(2) {
            match &resp {
                GraphicsResponse::Displayed {
                    image_id,
                    placement_id,
                } => {
                    self.last_reply = Some(format!("\x1b_Gi={image_id},p={placement_id};OK\x1b\\"));
                }
                GraphicsResponse::Stored { image_id } => {
                    self.last_reply = Some(format!("\x1b_Gi={image_id};OK\x1b\\"));
                }
                GraphicsResponse::Deleted { .. } => {
                    self.last_reply = Some("\x1b_G;OK\x1b\\".to_string());
                }
                GraphicsResponse::Error(msg) => {
                    self.last_reply = Some(format!("\x1b_G;{msg}\x1b\\"));
                }
                _ => {}
            }
        } else if let GraphicsResponse::Error(ref msg) = resp
            && cmd.get_u32('q') != Some(1)
            && action == 'q'
        {
            self.last_reply = Some(format!("\x1b_G;{msg}\x1b\\"));
        }

        resp
    }

    /// `a=t` / `a=T`: receive (possibly one chunk of) an image.
    fn transmit(
        &mut self,
        cmd: &GraphicsCommand,
        payload: &[u8],
        display: bool,
    ) -> GraphicsResponse {
        // Only the direct medium carries data in the payload. Anything else
        // (file, temp file, shared memory) is out of scope -- bail out before
        // touching the payload at all.
        if cmd.get_char('t') != Some('d') {
            return GraphicsResponse::Unsupported;
        }

        let format = match cmd.get('f') {
            None | Some("32") => ImageFormat::Rgba,
            Some("24") => ImageFormat::Rgb,
            Some("100") => ImageFormat::Png,
            Some(other) => return GraphicsResponse::Error(format!("unsupported format f={other}")),
        };

        let explicit_id = cmd.get_u32('i').or_else(|| cmd.get_u32('I'));
        let key = match explicit_id {
            Some(id) => ChunkKey::Image(id),
            None => ChunkKey::Anonymous,
        };

        let chunk = match BASE64.decode(payload) {
            Ok(bytes) => bytes,
            Err(err) => {
                // A bad chunk poisons the whole transmission; drop what we had
                // so the next command starts clean.
                self.pending.remove(&key);
                return GraphicsResponse::Error(format!("invalid base64 payload: {err}"));
            }
        };

        let declared_w = cmd.get_u32('s').unwrap_or(0);
        let declared_h = cmd.get_u32('v').unwrap_or(0);
        if declared_w > 0 && declared_h > 0 {
            let decoded = (declared_w as u64)
                .saturating_mul(declared_h as u64)
                .saturating_mul(4);
            if decoded > self.max_memory_bytes {
                self.pending.remove(&key);
                return GraphicsResponse::Error(
                    "image decoded size exceeds per-pane memory cap".to_string(),
                );
            }
        }
        if format == ImageFormat::Png
            && let Some((w, h)) = png_dimensions(&chunk)
        {
            let decoded = (w as u64).saturating_mul(h as u64).saturating_mul(4);
            if decoded > self.max_memory_bytes {
                self.pending.remove(&key);
                return GraphicsResponse::Error(
                    "image decoded size exceeds per-pane memory cap".to_string(),
                );
            }
        }

        let more = cmd.get('m').is_some_and(|m| m != "0");

        let additional_bytes = if let Some(existing) = self.pending.get(&key) {
            let needed = existing.data.len().saturating_add(chunk.len());
            if needed as u64 > self.max_memory_bytes {
                self.pending.remove(&key);
                return GraphicsResponse::Error(
                    "image transfer exceeds per-pane memory cap".to_string(),
                );
            }
            needed.saturating_sub(existing.data.capacity()) as u64
        } else {
            if chunk.len() as u64 > self.max_memory_bytes {
                return GraphicsResponse::Error(
                    "image transfer exceeds per-pane memory cap".to_string(),
                );
            }
            chunk.len() as u64
        };

        if !self.enforce_memory_cap(additional_bytes) {
            self.pending.remove(&key);
            return GraphicsResponse::Error(
                "image transfer exceeds per-pane memory cap".to_string(),
            );
        }

        let generation = self.allocate_pending_generation();
        // The first chunk carries the metadata; continuations only carry data.
        let entry = self.pending.entry(key).or_insert_with(|| PendingTransfer {
            format,
            width: cmd.get_u32('s').unwrap_or(0),
            height: cmd.get_u32('v').unwrap_or(0),
            generation,
            data: Vec::new(),
        });
        entry.generation = generation;
        if entry.data.capacity() < entry.data.len() + chunk.len() {
            entry.data.reserve_exact(chunk.len());
        }
        entry.data.extend_from_slice(&chunk);

        if more {
            // Still mid-transmission: acknowledge without storing or placing.
            return GraphicsResponse::Stored {
                image_id: explicit_id.unwrap_or(0),
            };
        }

        let mut transfer = self
            .pending
            .remove(&key)
            .expect("pending entry inserted immediately above");
        // A PNG carries its own size, and senders leave `s`/`v` out for it
        // (kitty's `icat` does). Without this the image was stored as 0x0 and
        // never drawn.
        if transfer.format == ImageFormat::Png
            && let Some((width, height)) = png_dimensions(&transfer.data)
        {
            transfer.width = width;
            transfer.height = height;
        }

        let decoded_bytes = (transfer.width as u64)
            .saturating_mul(transfer.height as u64)
            .saturating_mul(4);
        if transfer.width > 0 && transfer.height > 0 && decoded_bytes > self.max_memory_bytes {
            return GraphicsResponse::Error(
                "image decoded size exceeds per-pane memory cap".to_string(),
            );
        }

        let image_id = match explicit_id {
            Some(id) => id,
            None => self.allocate_image_id(),
        };

        let needed_bytes = (transfer.data.capacity() as u64).max(decoded_bytes);
        if !self.enforce_memory_cap(needed_bytes) {
            return GraphicsResponse::Error("image exceeds per-pane memory cap".to_string());
        }

        // Allocate from store-wide state rather than deriving this from the
        // current entry. A renderer may retain a texture after an image is
        // deleted, so delete + retransmit under the same explicit ID must not
        // reuse the old content generation.
        let generation = self.allocate_image_generation();

        self.images.insert(
            image_id,
            StoredImage {
                format: transfer.format,
                width: transfer.width,
                height: transfer.height,
                generation,
                pixels: transfer.data,
            },
        );

        if display {
            let placement_id = cmd.get_u32('p').unwrap_or(0);
            self.placements.push(Placement {
                image_id,
                placement_id,
            });
            GraphicsResponse::Displayed {
                image_id,
                placement_id,
            }
        } else {
            GraphicsResponse::Stored { image_id }
        }
    }

    /// `a=p`: place an image that was transmitted earlier.
    fn display_stored(&mut self, cmd: &GraphicsCommand) -> GraphicsResponse {
        let Some(image_id) = cmd.get_u32('i').or_else(|| cmd.get_u32('I')) else {
            return GraphicsResponse::Error("a=p requires an image id".to_string());
        };

        if !self.images.contains_key(&image_id) {
            return GraphicsResponse::Error(format!("unknown image id {image_id}"));
        }

        let placement_id = cmd.get_u32('p').unwrap_or(0);
        self.placements.push(Placement {
            image_id,
            placement_id,
        });
        GraphicsResponse::Displayed {
            image_id,
            placement_id,
        }
    }

    /// `a=d`: delete images and their placements.
    fn delete(&mut self, cmd: &GraphicsCommand) -> GraphicsResponse {
        match cmd.get_char('d') {
            // Lowercase deletes placements, uppercase also frees the image
            // data. We store no data separately from the image, so both clear
            // the same state.
            Some('a') | Some('A') => {
                let mut image_ids: Vec<u32> = self.images.keys().copied().collect();
                image_ids.sort_unstable();
                self.images.clear();
                self.placements.clear();
                self.pending.clear();
                GraphicsResponse::Deleted { image_ids }
            }
            Some('i') | Some('I') => {
                let Some(image_id) = cmd.get_u32('i').or_else(|| cmd.get_u32('I')) else {
                    return GraphicsResponse::Error("d=i requires an image id".to_string());
                };
                let mut image_ids = Vec::new();
                if self.images.remove(&image_id).is_some() {
                    image_ids.push(image_id);
                }
                self.placements.retain(|p| p.image_id != image_id);
                self.pending.remove(&ChunkKey::Image(image_id));
                GraphicsResponse::Deleted { image_ids }
            }
            _ => GraphicsResponse::Unsupported,
        }
    }

    /// `a=q`: query graphics protocol support.
    fn query(&mut self, cmd: &GraphicsCommand, _payload: &[u8]) -> GraphicsResponse {
        let medium = cmd.get_char('t').unwrap_or('d');
        if medium != 'd' {
            let mut keys = Vec::new();
            if let Some(i) = cmd.get_u32('i') {
                keys.push(format!("i={i}"));
            } else if let Some(big_i) = cmd.get_u32('I') {
                keys.push(format!("I={big_i}"));
            }
            let key_str = if keys.is_empty() {
                String::new()
            } else {
                format!("{};", keys.join(","))
            };
            let reply = format!("\x1b_G{}ENOTSUP\x1b\\", key_str);
            self.last_reply = Some(reply.clone());
            return GraphicsResponse::Query { reply };
        }

        let mut keys = Vec::new();
        if let Some(i) = cmd.get_u32('i') {
            keys.push(format!("i={i}"));
        } else if let Some(big_i) = cmd.get_u32('I') {
            keys.push(format!("I={big_i}"));
        }
        if let Some(p) = cmd.get_u32('p') {
            keys.push(format!("p={p}"));
        }
        if let Some(s) = cmd.get_u32('s') {
            keys.push(format!("s={s}"));
        }
        if let Some(v) = cmd.get_u32('v') {
            keys.push(format!("v={v}"));
        }

        let key_str = if keys.is_empty() {
            String::new()
        } else {
            format!("{};", keys.join(","))
        };

        let reply = format!("\x1b_G{}OK\x1b\\", key_str);
        self.last_reply = Some(reply.clone());
        GraphicsResponse::Query { reply }
    }
}
