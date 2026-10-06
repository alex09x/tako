/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::helpers::{b64, png_header};
use crate::graphics::*;

#[test]
fn memory_cap_enforces_limit_and_evicts_lru() {
    let mut state = GraphicsState::new();
    state.set_max_memory_bytes(10_000);

    let img1 = vec![0x11_u8; 3_000];
    let img2 = vec![0x22_u8; 3_000];
    let img3 = vec![0x33_u8; 5_000];

    state
        .store_and_place_raw_image(ImageFormat::Png, 10, 10, img1)
        .unwrap();
    state
        .store_and_place_raw_image(ImageFormat::Png, 10, 10, img2)
        .unwrap();
    assert_eq!(state.placements().len(), 2);

    state
        .store_and_place_raw_image(ImageFormat::Png, 10, 10, img3)
        .unwrap();
    assert!(state.image(1).is_none(), "oldest image evicted");
    assert!(state.image(2).is_some());
    assert!(state.image(3).is_some());

    let huge = vec![0xFF_u8; 20_000];
    assert!(
        state
            .store_and_place_raw_image(ImageFormat::Png, 10, 10, huge)
            .is_err()
    );
}

#[test]
fn multiple_pending_transfers_respect_aggregate_memory_cap() {
    let mut state = GraphicsState::new();
    state.set_max_memory_bytes(10_000);

    let chunk1 = vec![0x11_u8; 3_000];
    let chunk2 = vec![0x22_u8; 3_000];
    let chunk3 = vec![0x33_u8; 5_000];

    let r1 = state.handle("a=t,t=d,f=32,s=10,v=10,i=1,m=1", b64(&chunk1).as_bytes());
    assert_eq!(r1, GraphicsResponse::Stored { image_id: 1 });
    assert!(state.pending().contains_key(&ChunkKey::Image(1)));

    let r2 = state.handle("a=t,t=d,f=32,s=10,v=10,i=2,m=1", b64(&chunk2).as_bytes());
    assert_eq!(r2, GraphicsResponse::Stored { image_id: 2 });
    assert!(state.pending().contains_key(&ChunkKey::Image(2)));

    let r3 = state.handle("a=t,t=d,f=32,s=10,v=10,i=3,m=1", b64(&chunk3).as_bytes());
    assert_eq!(r3, GraphicsResponse::Stored { image_id: 3 });
    assert!(
        !state.pending().contains_key(&ChunkKey::Image(1)),
        "oldest pending transfer evicted"
    );
    assert!(state.pending().contains_key(&ChunkKey::Image(2)));
    assert!(state.pending().contains_key(&ChunkKey::Image(3)));
    assert!(state.retained_capacity_bytes() <= 10_000);
}

#[test]
fn compressed_png_with_oversized_decoded_dimensions_is_rejected() {
    let mut state = GraphicsState::new();
    let png = png_header(10_000, 10_000);
    assert!(png.len() < 100);

    let err = state.store_and_place_raw_image(ImageFormat::Png, 0, 0, png.clone());
    assert!(err.is_err());
    assert_eq!(
        err.unwrap_err(),
        "image decoded size exceeds per-pane memory cap"
    );

    let resp = state.handle("a=t,t=d,f=100,i=10", b64(&png).as_bytes());
    assert_eq!(
        resp,
        GraphicsResponse::Error("image decoded size exceeds per-pane memory cap".to_string())
    );
    assert!(state.image(10).is_none());
}

#[test]
fn multiple_compressed_pngs_exceeding_aggregate_decoded_budget_evict_lru() {
    let mut state = GraphicsState::new();
    state.set_max_memory_bytes(10_000);

    let png1 = png_header(40, 40);
    let png2 = png_header(40, 40);

    state
        .store_and_place_raw_image(ImageFormat::Png, 0, 0, png1)
        .expect("png1 fits");
    assert!(state.image(1).is_some());

    state
        .store_and_place_raw_image(ImageFormat::Png, 0, 0, png2)
        .expect("png2 fits after evicting png1");
    assert!(
        state.image(1).is_none(),
        "png1 evicted due to aggregate decoded memory cap"
    );
    assert!(state.image(2).is_some(), "png2 retained");
    assert!(state.retained_capacity_bytes() <= 10_000);
}
