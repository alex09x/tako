/*
 * tako — Terminal emulator
 * Copyright (c) 2026 Alexander Panasenko
 *
 * Contact: alex@prod.codes
 * Author: https://prod.codes/about/
 * Project: https://github.com/alex09x/tako
 * SPDX-License-Identifier: MIT
 */

use super::crc::crc32;
use super::encode::encode;
use super::reader::Reader;
use super::types::{
    CURRENT_VERSION, CheckpointError, CheckpointInfo, HEADER_SIZE, MAGIC, MAX_CONTAINER_LEN,
    MIN_EXPORT_VERSION, MIN_SUPPORTED_VERSION,
};
use crate::terminal::Terminal;

pub fn verify(data: &[u8]) -> bool {
    validate(data).is_ok()
}

pub fn validate(data: &[u8]) -> Result<(), CheckpointError> {
    validate_container(data).map(|_| ())
}

pub fn version() -> u32 {
    CURRENT_VERSION
}

pub fn supports(version: u32) -> bool {
    (MIN_SUPPORTED_VERSION..=CURRENT_VERSION).contains(&version)
}

pub fn inspect(data: &[u8]) -> Result<CheckpointInfo, CheckpointError> {
    let (_, payload) = validate_container(data)?;
    let mut r = Reader::new(payload);
    let cols = r.read_u32()?;
    let rows = r.read_u32()?;
    Ok(CheckpointInfo {
        version: u32::from_le_bytes([data[4], data[5], data[6], data[7]]),
        flags: u32::from_le_bytes([data[8], data[9], data[10], data[11]]),
        cols,
        rows,
        payload_len: payload.len() as u32,
    })
}

pub(crate) fn validate_container(data: &[u8]) -> Result<(u32, &[u8]), CheckpointError> {
    if data.len() < HEADER_SIZE {
        return Err(CheckpointError::UnexpectedEof);
    }
    if data[0..4] != MAGIC {
        return Err(CheckpointError::InvalidMagic);
    }
    let version = u32::from_le_bytes([data[4], data[5], data[6], data[7]]);
    if !supports(version) {
        return Err(CheckpointError::UnsupportedVersion(version));
    }
    let payload_len = u32::from_le_bytes([data[12], data[13], data[14], data[15]]) as usize;
    let container_len = (HEADER_SIZE as u64).saturating_add(payload_len as u64);
    if container_len > MAX_CONTAINER_LEN as u64 {
        return Err(CheckpointError::TooLarge {
            size: container_len,
            limit: MAX_CONTAINER_LEN as u64,
        });
    }
    if data.len() != HEADER_SIZE + payload_len {
        return Err(CheckpointError::InvalidPayloadLength {
            declared: payload_len,
            actual: data.len().saturating_sub(HEADER_SIZE),
        });
    }
    let expected_crc = u32::from_le_bytes([data[16], data[17], data[18], data[19]]);
    let actual_crc = crc32(&data[HEADER_SIZE..]);
    if expected_crc != actual_crc {
        return Err(CheckpointError::ChecksumMismatch {
            expected: expected_crc,
            actual: actual_crc,
        });
    }
    Ok((version, &data[HEADER_SIZE..]))
}

pub fn export(term: &Terminal) -> Result<Vec<u8>, CheckpointError> {
    export_limited(term, MAX_CONTAINER_LEN as u64)
}

pub fn export_limited(term: &Terminal, max_bytes: u64) -> Result<Vec<u8>, CheckpointError> {
    export_version(term, CURRENT_VERSION, max_bytes)
}

pub fn export_version(
    term: &Terminal,
    version: u32,
    max_bytes: u64,
) -> Result<Vec<u8>, CheckpointError> {
    let version = export_target(version)?;
    let limit = effective_limit(max_bytes);
    let mut w = encode(term, limit, true, version)?;

    let payload_len = (w.buf.len() - HEADER_SIZE) as u32;
    let checksum = crc32(&w.buf[HEADER_SIZE..]);

    w.buf[0..4].copy_from_slice(&MAGIC);
    w.buf[4..8].copy_from_slice(&version.to_le_bytes());
    w.buf[8..12].copy_from_slice(&0u32.to_le_bytes()); // flags
    w.buf[12..16].copy_from_slice(&payload_len.to_le_bytes());
    w.buf[16..20].copy_from_slice(&checksum.to_le_bytes());

    Ok(w.buf)
}

pub fn measure(term: &Terminal) -> Result<u64, CheckpointError> {
    measure_limited(term, MAX_CONTAINER_LEN as u64)
}

pub fn measure_limited(term: &Terminal, max_bytes: u64) -> Result<u64, CheckpointError> {
    measure_version(term, CURRENT_VERSION, max_bytes)
}

pub fn measure_version(
    term: &Terminal,
    version: u32,
    max_bytes: u64,
) -> Result<u64, CheckpointError> {
    let version = export_target(version)?;
    let limit = effective_limit(max_bytes);
    Ok(encode(term, limit, false, version)?.count as u64)
}

fn export_target(version: u32) -> Result<u32, CheckpointError> {
    match version {
        0 => Ok(CURRENT_VERSION),
        v if (MIN_EXPORT_VERSION..=CURRENT_VERSION).contains(&v) => Ok(v),
        v => Err(CheckpointError::UnsupportedVersion(v)),
    }
}

fn effective_limit(max_bytes: u64) -> u64 {
    if max_bytes == 0 {
        MAX_CONTAINER_LEN as u64
    } else {
        max_bytes.min(MAX_CONTAINER_LEN as u64)
    }
}
