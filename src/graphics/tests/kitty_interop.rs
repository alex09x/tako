/*
 * tako — Terminal emulator core library
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::helpers::b64;
use crate::graphics::{GraphicsResponse, GraphicsState};
use crate::terminal::Terminal;

#[test]
fn kitty_interop_icat_stream_defaults_to_direct_and_is_quiet() {
    let image = include_bytes!("../../../brand/out/TakoCore.iconset/icon_128x128.png");
    let mut term = Terminal::new(80, 24);
    // The control keys come from `kitten icat --transfer-mode=stream`.
    let command = format!("\x1b_Ga=T,q=2,f=100,s=128,v=128,X=1;{}\x1b\\", b64(image));
    term.feed(command.as_bytes());
    let placement = term
        .graphics_placements()
        .first()
        .expect("icat image was not displayed");
    assert_eq!(
        term.graphics_image(placement.image_id).unwrap().pixels,
        image
    );
    assert!(
        term.take_output().is_empty(),
        "quiet output must not reach the shell"
    );
}

#[test]
fn kitty_interop_quiet_modes_control_success_and_error_replies() {
    let mut state = GraphicsState::new();
    state.handle("a=q,t=d,i=4,q=1", b"");
    assert_eq!(state.take_last_reply(), None);
    state.handle("a=q,t=f,i=4,q=1", b"");
    assert!(state.take_last_reply().unwrap().contains("ENOTSUP"));
    state.handle("a=q,t=f,i=4,q=2", b"");
    assert_eq!(state.take_last_reply(), None);
    state.handle(
        "a=T,t=d,i=4,f=32,s=1,v=1,q=2",
        b64(&[1, 2, 3, 4]).as_bytes(),
    );
    assert_eq!(state.take_last_reply(), None);
}

#[test]
fn kitty_interop_continuation_retains_first_chunk_identity_and_placement() {
    let mut state = GraphicsState::new();
    state.handle("a=T,i=7,p=11,f=32,s=1,v=1,m=1,q=2", b"AQID");
    assert!(state.image(7).is_none());
    let response = state.handle("m=0", b"BA==");
    assert_eq!(
        response,
        GraphicsResponse::Displayed {
            image_id: 7,
            placement_id: 11
        }
    );
    assert_eq!(state.image(7).unwrap().pixels, [1, 2, 3, 4]);
    assert_eq!(state.placements().len(), 1);
    assert_eq!(state.take_last_reply(), None);
}

#[test]
fn kitty_interop_partial_transfer_survives_checkpoint() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b_Ga=T,i=7,p=11,f=32,s=1,v=1,m=1,q=2;AQID\x1b\\");
    assert!(
        term.export_checkpoint_version(6, 0).is_err(),
        "older checkpoints cannot retain this transfer's display metadata"
    );
    let checkpoint = term.export_checkpoint().unwrap();
    let mut restored = Terminal::new(80, 24);
    restored.import_checkpoint(&checkpoint).unwrap();
    restored.feed(b"\x1b_Gm=0;BA==\x1b\\");
    let placement = restored
        .graphics_placements()
        .first()
        .expect("restored transfer was not displayed");
    assert_eq!((placement.image_id, placement.placement_id), (7, 11));
    assert_eq!(restored.graphics_image(7).unwrap().pixels, [1, 2, 3, 4]);
    assert!(restored.take_output().is_empty());
}

#[test]
fn kitty_interop_v6_checkpoint_keeps_legacy_transmit_only_continuation() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b_Ga=t,t=d,i=7,f=32,s=1,v=1,m=1;AQID\x1b\\");
    let checkpoint = term.export_checkpoint_version(6, 0).unwrap();
    let mut restored = Terminal::new(80, 24);
    restored.import_checkpoint(&checkpoint).unwrap();
    restored.feed(b"\x1b_Ga=t,t=d,i=7,m=0;BA==\x1b\\");
    assert_eq!(restored.graphics_image(7).unwrap().pixels, [1, 2, 3, 4]);
    assert!(restored.graphics_placements().is_empty());
}

#[test]
fn kitty_interop_chunked_cursor_policy_and_extent_survive_checkpoint() {
    let mut term = Terminal::new(80, 24);
    term.resize_with_cell_size(80, 24, 10, 20);
    term.feed(b"\x1b[3;4H\x1b_Ga=T,i=9,f=32,s=1,v=1,c=3,r=2,X=1,Y=2,C=1,m=1,q=2;AQID\x1b\\");
    let checkpoint = term.export_checkpoint().unwrap();
    let mut restored = Terminal::new(80, 24);
    restored.import_checkpoint(&checkpoint).unwrap();
    restored.feed(b"\x1b_Gm=0;BA==\x1b\\");
    assert_eq!(
        restored.cursor(),
        (2, 3),
        "C=1 from the first chunk must keep the cursor still"
    );
    assert_eq!(restored.graphics_placements().len(), 1);
    let options = restored.graphics_placements()[0].options;
    assert_eq!(
        (
            options.columns,
            options.rows,
            options.offset_x,
            options.offset_y
        ),
        (3, 2, 1, 2)
    );
    let after_display = restored.export_checkpoint().unwrap();
    let mut again = Terminal::new(80, 24);
    again.import_checkpoint(&after_display).unwrap();
    assert_eq!(again.graphics_placements()[0].options, options);
}

#[test]
fn kitty_interop_cursor_moves_by_the_placement_rectangle() {
    let mut term = Terminal::new(80, 24);
    term.resize_with_cell_size(80, 24, 10, 20);
    term.feed(b"\x1b[3;4H\x1b_Ga=T,f=32,s=1,v=1,c=3,r=2,q=2;AQIDBA==\x1b\\");
    assert_eq!(term.cursor(), (4, 6));
}

#[test]
fn kitty_interop_placement_geometry_reaches_render_snapshots() {
    let core = crate::ffi::TakoCore::new(80, 24);
    core.feed(
        b"\x1b_Ga=T,f=32,s=1,v=1,c=3,r=2,X=1,Y=2,x=0,y=0,w=1,h=1,C=1,q=2;AQIDBA==\x1b\\".to_vec(),
    );
    let placements = core.graphics_placements();
    let placement = &placements[0];
    assert_eq!(
        (
            placement.columns,
            placement.rows,
            placement.offset_x,
            placement.offset_y
        ),
        (3, 2, 1, 2)
    );
    assert_eq!(
        (
            placement.source_x,
            placement.source_y,
            placement.source_width,
            placement.source_height
        ),
        (0, 0, 1, 1)
    );
    assert_eq!(core.snapshot().graphics_placements, placements);
}

#[test]
fn kitty_interop_compressed_image_and_chunks_are_decoded() {
    let mut term = Terminal::new(80, 24);
    // zlib-compressed RGBA pixel [1, 2, 3, 4], as used by kitten when resizing.
    term.feed(b"\x1b_Ga=T,o=z,i=31,f=32,s=1,v=1,m=1,q=2;eJxj\x1b\\");
    let checkpoint = term.export_checkpoint().unwrap();
    let mut restored = Terminal::new(80, 24);
    restored.import_checkpoint(&checkpoint).unwrap();
    restored.feed(b"\x1b_Gm=0;ZGJmAQAAGAAL\x1b\\");
    assert_eq!(restored.graphics_image(31).unwrap().pixels, [1, 2, 3, 4]);
    assert_eq!(restored.graphics_placements().len(), 1);
    assert!(restored.take_output().is_empty());
}

#[test]
fn kitty_interop_rejects_invalid_or_unsupported_compression() {
    let mut state = GraphicsState::new();
    assert!(matches!(
        state.handle("a=T,o=z,i=3,f=32,s=1,v=1", b"AAAA"),
        GraphicsResponse::Error(_)
    ));
    assert!(state.image(3).is_none());
    assert!(matches!(
        state.handle("a=T,o=x,i=4,f=32,s=1,v=1", b"AQIDBA=="),
        GraphicsResponse::Error(_)
    ));
    assert!(state.image(4).is_none());
}

#[test]
fn kitty_interop_rejects_truncated_and_over_budget_compressed_data() {
    use std::io::Write;
    let mut state = GraphicsState::new();
    assert!(matches!(
        state.handle("a=T,o=z,i=3,f=32,s=1,v=1", b"eJxjZGJmAQAAGAA="),
        GraphicsResponse::Error(_)
    ));
    assert!(state.image(3).is_none());

    state.set_max_memory_bytes(8192);
    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(&vec![42; 32_768]).unwrap();
    let compressed = encoder.finish().unwrap();
    assert!(matches!(
        state.handle("a=t,o=z,i=4,f=100", b64(&compressed).as_bytes()),
        GraphicsResponse::Error(_)
    ));
    assert!(state.image(4).is_none());
}

#[test]
fn kitty_interop_inflates_images_larger_than_one_decoder_buffer() {
    use std::io::Write;
    let pixels: Vec<u8> = (0..80_000).map(|i| (i % 251) as u8).collect();
    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(&pixels).unwrap();
    let compressed = encoder.finish().unwrap();
    let mut state = GraphicsState::new();
    let result = state.handle("a=t,o=z,i=17,f=32,s=200,v=100", b64(&compressed).as_bytes());
    assert_eq!(result, GraphicsResponse::Stored { image_id: 17 });
    assert_eq!(state.image(17).unwrap().pixels, pixels);
}

#[test]
fn kitty_interop_placed_icat_rgb_reaches_the_terminal_snapshot() {
    use std::io::Write;
    let pixels: Vec<u8> = [0, 255, 255].repeat(40 * 40);
    let mut encoder = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::default());
    encoder.write_all(&pixels).unwrap();
    let payload = b64(&encoder.finish().unwrap());
    let command = format!("\x1b[1;1H\x1b_Ga=T,q=2,f=24,o=z,C=1,s=40,v=40;{payload}\x1b\\");
    let core = crate::ffi::TakoCore::new(80, 24);
    core.feed(command.into_bytes());
    let placement = core.snapshot().graphics_placements[0];
    let image = core.graphics_image(placement.image_id).unwrap();
    assert_eq!(image.format, crate::ffi::FfiImageFormat::Rgb);
    assert_eq!((image.width, image.height), (40, 40));
    assert_eq!(image.pixels, pixels);
    assert!(core.take_output().is_empty());
}

#[test]
fn kitty_interop_accepts_the_unpadded_stream_emitted_by_icat() {
    let mut term = Terminal::new(80, 24);
    term.feed(b"\x1b_Ga=T,q=2,f=24,o=z,C=1,s=40,v=40;eJzswjENAAAIBDH8mz5s/NCkVwAAAAAw6wMAAP//ug90NQ\x1b\\");
    let placement = term
        .graphics_placements()
        .first()
        .expect("icat stream was not displayed");
    let image = term.graphics_image(placement.image_id).unwrap();
    assert_eq!((image.width, image.height), (40, 40));
    assert_eq!(image.pixels, [0, 255, 255].repeat(40 * 40));
    assert!(term.take_output().is_empty());
}

mod geometry;
