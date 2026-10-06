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
fn transmit_and_display_stores_image_and_records_placement() {
    let mut state = GraphicsState::new();
    // 1x1 RGBA pixel: opaque orange.
    let pixel = [0xFF_u8, 0x80, 0x00, 0xFF];

    let resp = state.handle("a=T,t=d,f=32,s=1,v=1,i=7", b64(&pixel).as_bytes());
    assert_eq!(
        resp,
        GraphicsResponse::Displayed {
            image_id: 7,
            placement_id: 0
        }
    );

    let img = state.image(7).expect("image 7 stored");
    assert_eq!(img.format, ImageFormat::Rgba);
    assert_eq!(img.width, 1);
    assert_eq!(img.height, 1);
    assert_eq!(img.pixels, pixel.to_vec());

    assert_eq!(state.placements().len(), 1);
    assert_eq!(state.placements()[0].image_id, 7);
}

#[test]
fn repeated_reads_do_not_change_generation_or_payload() {
    let mut state = GraphicsState::new();
    let pixel = [0xAA_u8, 0xBB, 0xCC, 0xDD];
    let response = state.handle("a=T,t=d,f=32,s=1,v=1,i=7", b64(&pixel).as_bytes());
    assert_eq!(
        response,
        GraphicsResponse::Displayed {
            image_id: 7,
            placement_id: 0
        }
    );

    let first = state.image(7).expect("image 7 stored");
    assert_eq!(first.format, ImageFormat::Rgba);
    assert_eq!(first.width, 1);
    assert_eq!(first.height, 1);
    assert_eq!(first.generation, 1);
    assert_eq!(first.pixels, pixel.to_vec());

    let second = state.image(7).expect("image 7 stored");
    assert_eq!(second.format, first.format);
    assert_eq!(second.width, first.width);
    assert_eq!(second.height, first.height);
    assert_eq!(second.generation, first.generation);
    assert_eq!(second.pixels, first.pixels);
    assert_eq!(
        state.placements(),
        &[Placement {
            image_id: 7,
            placement_id: 0
        }]
    );
}

#[test]
fn replacing_and_recreating_an_explicit_id_advance_generation() {
    let mut state = GraphicsState::new();
    let first = [0x01_u8, 0x02, 0x03, 0x04];
    let second = [0xFE_u8, 0xDC, 0xBA, 0x98];
    let third = [0x10_u8, 0x20, 0x30, 0x40];

    let first_response = state.handle("a=T,t=d,f=32,s=1,v=1,i=7", b64(&first).as_bytes());
    assert_eq!(
        first_response,
        GraphicsResponse::Displayed {
            image_id: 7,
            placement_id: 0
        }
    );
    let first_generation = state.image(7).expect("image 7 stored first").generation;

    let second_response = state.handle("a=t,t=d,f=32,s=1,v=1,i=7", b64(&second).as_bytes());
    assert_eq!(second_response, GraphicsResponse::Stored { image_id: 7 });

    let second_image = state.image(7).expect("image 7 stored second");
    assert_eq!(second_image.generation, first_generation + 1);
    assert_eq!(second_image.generation, 2);
    assert_eq!(second_image.pixels, second.to_vec());
    assert_eq!(second_image.width, 1);
    assert_eq!(second_image.height, 1);
    assert_eq!(
        state.placements(),
        &[Placement {
            image_id: 7,
            placement_id: 0
        }]
    );

    assert_eq!(
        state.handle("a=d,d=i,i=7", b""),
        GraphicsResponse::Deleted { image_ids: vec![7] }
    );
    assert!(state.image(7).is_none());

    assert_eq!(
        state.handle("a=t,t=d,f=32,s=1,v=1,i=7", b64(&third).as_bytes()),
        GraphicsResponse::Stored { image_id: 7 }
    );
    let recreated = state.image(7).expect("image 7 recreated");
    assert_eq!(recreated.generation, 3);
    assert_ne!(recreated.generation, first_generation);
    assert_eq!(recreated.pixels, third.to_vec());
}

#[test]
fn transmit_only_does_not_place() {
    let mut state = GraphicsState::new();
    let pixel = [1_u8, 2, 3, 4];

    let resp = state.handle("a=t,t=d,f=32,s=1,v=1,i=3", b64(&pixel).as_bytes());
    assert_eq!(resp, GraphicsResponse::Stored { image_id: 3 });
    assert!(state.image(3).is_some());
    assert!(state.placements().is_empty());
}

#[test]
fn rgb_and_png_formats_are_recognized() {
    let mut state = GraphicsState::new();

    let rgb = [9_u8, 8, 7];
    state.handle("a=t,t=d,f=24,s=1,v=1,i=1", b64(&rgb).as_bytes());
    let img = state.image(1).expect("rgb image stored");
    assert_eq!(img.format, ImageFormat::Rgb);
    assert_eq!(img.pixels, rgb.to_vec());

    // PNG bytes are stored verbatim -- no decoding here.
    let png = b"\x89PNG\r\n\x1a\n-not-really-a-png";
    state.handle("a=t,t=d,f=100,i=2", b64(png).as_bytes());
    let img = state.image(2).expect("png image stored");
    assert_eq!(img.format, ImageFormat::Png);
    assert_eq!(img.pixels, png.to_vec());
}

#[test]
fn a_png_sent_without_its_size_takes_it_from_its_header() {
    // What `kitten icat` sends: f=100 and no s/v.
    let mut state = GraphicsState::new();
    state.handle("a=T,t=d,f=100,i=5", b64(&png_header(256, 128)).as_bytes());
    let img = state.image(5).expect("png stored");
    assert_eq!((img.width, img.height), (256, 128));
}

#[test]
fn a_pngs_own_header_wins_over_a_wrong_size() {
    let mut state = GraphicsState::new();
    state.handle(
        "a=T,t=d,f=100,s=1,v=1,i=5",
        b64(&png_header(40, 30)).as_bytes(),
    );
    let img = state.image(5).expect("png stored");
    assert_eq!((img.width, img.height), (40, 30));
}

#[test]
fn a_chunked_png_is_sized_from_the_whole_transfer() {
    let png = png_header(640, 480);
    let mut state = GraphicsState::new();
    state.handle("a=T,t=d,f=100,i=6,m=1", b64(&png[..18]).as_bytes());
    state.handle("a=T,t=d,i=6,m=0", b64(&png[18..]).as_bytes());
    let img = state.image(6).expect("png stored");
    assert_eq!((img.width, img.height), (640, 480));
}

#[test]
fn a_png_header_claiming_an_undrawable_size_is_not_believed() {
    let mut state = GraphicsState::new();
    for (i, (w, h)) in [(100_000, 10), (10, 0), (MAX_PNG_SIDE + 1, 1)]
        .into_iter()
        .enumerate()
    {
        let id = 10 + i as u32;
        state.handle(
            &format!("a=t,t=d,f=100,i={id}"),
            b64(&png_header(w, h)).as_bytes(),
        );
        let img = state.image(id).expect("png stored");
        assert_eq!((img.width, img.height), (0, 0), "{w}x{h}");
    }
    state.handle(
        "a=t,t=d,f=100,i=20",
        b64(&png_header(MAX_PNG_SIDE, 1)).as_bytes(),
    );
    assert_eq!(state.image(20).map(|img| img.width), Some(MAX_PNG_SIDE));
}

#[test]
fn missing_format_defaults_to_rgba_and_bad_format_errors() {
    let mut state = GraphicsState::new();
    state.handle("a=t,t=d,s=1,v=1,i=5", b64(&[1, 2, 3, 4]).as_bytes());
    assert_eq!(state.image(5).unwrap().format, ImageFormat::Rgba);

    let resp = state.handle("a=t,t=d,f=17,i=6", b64(&[0]).as_bytes());
    assert!(matches!(resp, GraphicsResponse::Error(_)));
    assert!(state.image(6).is_none());
}

#[test]
fn omitted_image_id_auto_assigns_distinct_ids() {
    let mut state = GraphicsState::new();
    let payload = b64(&[0_u8, 0, 0, 0]);

    let first = state.handle("a=t,t=d,f=32,s=1,v=1", payload.as_bytes());
    let second = state.handle("a=t,t=d,f=32,s=1,v=1", payload.as_bytes());

    let (GraphicsResponse::Stored { image_id: a }, GraphicsResponse::Stored { image_id: b }) =
        (first, second)
    else {
        panic!("expected two Stored responses");
    };
    assert_eq!(a, 1);
    assert_ne!(a, b);
    assert!(state.image(a).is_some());
    assert!(state.image(b).is_some());
}

#[test]
fn display_existing_image_and_reject_unknown_id() {
    let mut state = GraphicsState::new();
    state.handle("a=t,t=d,f=32,s=1,v=1,i=4", b64(&[1, 1, 1, 1]).as_bytes());
    assert!(state.placements().is_empty());

    let resp = state.handle("a=p,i=4,p=11", b"");
    assert_eq!(
        resp,
        GraphicsResponse::Displayed {
            image_id: 4,
            placement_id: 11
        }
    );
    assert_eq!(
        state.placements(),
        &[Placement {
            image_id: 4,
            placement_id: 11
        }]
    );

    let resp = state.handle("a=p,i=999", b"");
    assert!(matches!(resp, GraphicsResponse::Error(_)));
    assert_eq!(state.placements().len(), 1);
}

#[test]
fn delete_single_image_leaves_others_intact() {
    let mut state = GraphicsState::new();
    state.handle("a=T,t=d,f=32,s=1,v=1,i=7", b64(&[1, 2, 3, 4]).as_bytes());
    state.handle("a=T,t=d,f=32,s=1,v=1,i=8", b64(&[5, 6, 7, 8]).as_bytes());
    assert_eq!(state.placements().len(), 2);

    let resp = state.handle("a=d,d=i,i=7", b"");
    assert_eq!(resp, GraphicsResponse::Deleted { image_ids: vec![7] });
    assert!(state.image(7).is_none());
    assert!(state.image(8).is_some());
    assert_eq!(
        state.placements(),
        &[Placement {
            image_id: 8,
            placement_id: 0
        }]
    );

    // Deleting a missing id is not an error, just an empty result.
    let resp = state.handle("a=d,d=i,i=7", b"");
    assert_eq!(resp, GraphicsResponse::Deleted { image_ids: vec![] });
}

#[test]
fn delete_all_clears_images_and_placements() {
    let mut state = GraphicsState::new();
    state.handle("a=T,t=d,f=32,s=1,v=1,i=2", b64(&[1, 2, 3, 4]).as_bytes());
    state.handle("a=T,t=d,f=32,s=1,v=1,i=5", b64(&[5, 6, 7, 8]).as_bytes());

    let resp = state.handle("a=d,d=a", b"");
    assert_eq!(
        resp,
        GraphicsResponse::Deleted {
            image_ids: vec![2, 5]
        }
    );
    assert!(state.image(2).is_none());
    assert!(state.image(5).is_none());
    assert!(state.placements().is_empty());
}

#[test]
fn unsupported_delete_sub_action_and_missing_d_key() {
    let mut state = GraphicsState::new();
    assert_eq!(state.handle("a=d,d=c", b""), GraphicsResponse::Unsupported);
    assert_eq!(state.handle("a=d", b""), GraphicsResponse::Unsupported);
}

#[test]
fn chunked_transmission_assembles_across_calls() {
    let mut state = GraphicsState::new();
    let first_half = [0xDE_u8, 0xAD, 0xBE, 0xEF];
    let second_half = [0x01_u8, 0x02, 0x03, 0x04];

    let resp = state.handle("a=T,t=d,f=32,s=2,v=1,i=42,m=1", b64(&first_half).as_bytes());
    assert!(matches!(resp, GraphicsResponse::Stored { .. }));
    assert!(state.image(42).is_none());
    assert!(state.placements().is_empty());

    let resp = state.handle("a=T,t=d,i=42", b64(&second_half).as_bytes());
    assert_eq!(
        resp,
        GraphicsResponse::Displayed {
            image_id: 42,
            placement_id: 0
        }
    );

    let img = state.image(42).expect("assembled image stored");
    assert_eq!(img.format, ImageFormat::Rgba);
    assert_eq!(img.width, 2);
    assert_eq!(img.height, 1);
    assert_eq!(img.pixels, [first_half, second_half].concat());
    assert_eq!(state.placements().len(), 1);
}

#[test]
fn explicit_m0_terminates_a_chunked_transmission() {
    let mut state = GraphicsState::new();
    state.handle("a=t,t=d,f=24,s=2,v=1,i=9,m=1", b64(&[1, 2, 3]).as_bytes());
    let resp = state.handle("a=t,t=d,i=9,m=0", b64(&[4, 5, 6]).as_bytes());
    assert_eq!(resp, GraphicsResponse::Stored { image_id: 9 });
    assert_eq!(state.image(9).unwrap().pixels, vec![1, 2, 3, 4, 5, 6]);
}

#[test]
fn unsupported_transmission_medium_is_reported_not_decoded() {
    let mut state = GraphicsState::new();
    assert_eq!(
        state.handle("a=T,t=f,f=32,s=1,v=1,i=1", b"/tmp/some/file.png"),
        GraphicsResponse::Unsupported
    );
    assert_eq!(
        state.handle("a=t,f=32,s=1,v=1,i=1", b"AAAA"),
        GraphicsResponse::Unsupported
    );
    assert!(state.image(1).is_none());
}

#[test]
fn malformed_base64_errors_without_panicking() {
    let mut state = GraphicsState::new();
    let resp = state.handle("a=T,t=d,f=32,s=1,v=1,i=1", b"!!!not base64!!!");
    assert!(matches!(resp, GraphicsResponse::Error(_)));
    assert!(state.image(1).is_none());
    assert!(state.placements().is_empty());
}
