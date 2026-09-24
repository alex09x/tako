#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum State {
    Ground,
    Escape,
    EscapeIntermediate,
    CsiEntry,
    CsiParam,
    CsiIntermediate,
    CsiIgnore,
    DcsEntry,
    DcsParam,
    DcsIntermediate,
    DcsPassthrough,
    DcsIgnore,
    OscString,
    SosPmApcString,
}

pub trait Perform {
    fn print(&mut self, c: char);
    /// Print a contiguous run of ground-state ASCII bytes. Implementors may
    /// batch this; the default is exactly equivalent to `print` per byte.
    fn print_slice(&mut self, bytes: &[u8]) {
        for &byte in bytes {
            self.print(byte as char);
        }
    }
    fn execute(&mut self, byte: u8);
    fn hook(&mut self, params: &[u16], params_sep: u32, intermediates: &[u8], ignore: bool, action: char);
    fn put(&mut self, byte: u8);
    fn unhook(&mut self);
    fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool);
    fn csi_dispatch(&mut self, params: &[u16], params_sep: u32, intermediates: &[u8], ignore: bool, action: char);
    fn esc_dispatch(&mut self, intermediates: &[u8], ignore: bool, byte: u8);
    fn apc_dispatch(&mut self, data: &[u8]) {
        let _ = data;
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParserSnapshot {
    pub state: State,
    pub intermediates: smallvec::SmallVec<[u8; 2]>,
    pub params: smallvec::SmallVec<[u16; 16]>,
    pub params_sep: u32,
    pub ignore: bool,
    pub osc_raw: Vec<u8>,
    pub apc_raw: Vec<u8>,
    pub utf8_need: u8,
    pub utf8_cp: u32,
}

/// A borrowed read of [`Parser`]'s serializable state. Same fields as
/// [`ParserSnapshot`], none of its copies.
pub struct ParserView<'a> {
    pub state: State,
    pub intermediates: &'a [u8],
    pub params: &'a [u16],
    pub params_sep: u32,
    pub ignore: bool,
    pub osc_raw: &'a [u8],
    pub apc_raw: &'a [u8],
    pub utf8_need: u8,
    pub utf8_cp: u32,
}

pub struct Parser {
    pub state: State,
    intermediates: smallvec::SmallVec<[u8; 2]>,
    params: smallvec::SmallVec<[u16; 16]>,
    params_sep: u32, // Bitset: 1 if preceded by ':', 0 if ';'
    ignore: bool,
    osc_raw: Vec<u8>,
    apc_raw: Vec<u8>,
    utf8_need: u8,
    utf8_cp: u32,
}

impl Default for Parser {
    fn default() -> Self {
        Self::new()
    }
}

impl Parser {
    pub fn new() -> Self {
        Self {
            state: State::Ground,
            intermediates: smallvec::SmallVec::new(),
            params: smallvec::SmallVec::new(),
            params_sep: 0,
            ignore: false,
            osc_raw: Vec::new(),
            apc_raw: Vec::new(),
            utf8_need: 0,
            utf8_cp: 0,
        }
    }

    /// The same state [`Self::snapshot`] copies, borrowed instead of cloned.
    ///
    /// `snapshot` exists to be *stored*, so it owns its buffers. Measuring or
    /// serializing a checkpoint only reads them, and an in-flight OSC or APC
    /// payload is bounded by nothing but the host's input -- so going through
    /// `snapshot` there made the cost of asking "how big is this checkpoint?"
    /// proportional to the payload. This view costs nothing.
    pub fn view(&self) -> ParserView<'_> {
        ParserView {
            state: self.state,
            intermediates: &self.intermediates,
            params: &self.params,
            params_sep: self.params_sep,
            ignore: self.ignore,
            osc_raw: &self.osc_raw,
            apc_raw: &self.apc_raw,
            utf8_need: self.utf8_need,
            utf8_cp: self.utf8_cp,
        }
    }

    /// Heap this parser holds, counted by *capacity* rather than length.
    ///
    /// `osc_raw` and `apc_raw` are cleared with `Vec::clear`, which drops the
    /// length and keeps the allocation: a parser that has just finished an
    /// 8 MiB OSC still owns 8 MiB of heap while reporting a length of zero.
    /// Anything reasoning about the memory a live terminal occupies has to ask
    /// this, not `len()`.
    pub fn retained_capacity_bytes(&self) -> u64 {
        let inter = if self.intermediates.spilled() {
            self.intermediates.capacity() as u64
        } else {
            0
        };
        let params = if self.params.spilled() {
            (self.params.capacity() as u64).saturating_mul(2)
        } else {
            0
        };
        (self.osc_raw.capacity() as u64)
            .saturating_add(self.apc_raw.capacity() as u64)
            .saturating_add(inter)
            .saturating_add(params)
    }

    pub fn snapshot(&self) -> ParserSnapshot {
        ParserSnapshot {
            state: self.state,
            intermediates: self.intermediates.clone(),
            params: self.params.clone(),
            params_sep: self.params_sep,
            ignore: self.ignore,
            osc_raw: self.osc_raw.clone(),
            apc_raw: self.apc_raw.clone(),
            utf8_need: self.utf8_need,
            utf8_cp: self.utf8_cp,
        }
    }

    pub fn restore(&mut self, snap: ParserSnapshot) {
        self.state = snap.state;
        self.intermediates = snap.intermediates;
        self.params = snap.params;
        self.params_sep = snap.params_sep;
        self.ignore = snap.ignore;
        self.osc_raw = snap.osc_raw;
        self.apc_raw = snap.apc_raw;
        self.utf8_need = snap.utf8_need;
        self.utf8_cp = snap.utf8_cp;
    }

    fn push_param(&mut self, digit: u8) {
        let val = (digit - b'0') as u16;
        if let Some(last) = self.params.last_mut() {
            *last = last.saturating_mul(10).saturating_add(val);
        } else {
            self.params.push(val);
        }
    }

    fn new_param(&mut self, is_colon: bool) {
        if self.params.is_empty() {
            self.params.push(0);
        }
        if self.params.len() < 16 {
            if is_colon {
                self.params_sep |= 1 << (self.params.len() - 1);
            }
            self.params.push(0);
        }
    }

    fn push_intermediate(&mut self, byte: u8) {
        if self.intermediates.len() < 16 {
            self.intermediates.push(byte);
        } else {
            self.ignore = true;
        }
    }

    fn clear(&mut self) {
        self.intermediates.clear();
        self.params.clear();
        self.params_sep = 0;
        self.ignore = false;
        self.utf8_need = 0;
    }

    pub fn advance<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        let mut transition = None;
        let mut execute = false;

        match self.state {
            State::Ground => {
                if byte < 0x80 {
                    // A control/ASCII byte abandons any in-flight UTF-8
                    // sequence rather than corrupting the next one.
                    self.utf8_need = 0;
                }
                match byte {
                    0x00..=0x17 | 0x19 | 0x1C..=0x1F => execute = true,
                    0x18 | 0x1A => { execute = true; transition = Some(State::Ground); },
                    0x1B => transition = Some(State::Escape),
                    0x20..=0x7F => performer.print(byte as char),
                    0xC2..=0xDF => { self.utf8_need = 1; self.utf8_cp = (byte & 0x1F) as u32; }
                    0xE0..=0xEF => { self.utf8_need = 2; self.utf8_cp = (byte & 0x0F) as u32; }
                    0xF0..=0xF4 => { self.utf8_need = 3; self.utf8_cp = (byte & 0x07) as u32; }
                    0x80..=0xBF => {
                        if self.utf8_need > 0 {
                            self.utf8_cp = (self.utf8_cp << 6) | (byte & 0x3F) as u32;
                            self.utf8_need -= 1;
                            if self.utf8_need == 0 {
                                performer.print(char::from_u32(self.utf8_cp).unwrap_or('\u{FFFD}'));
                            }
                        } else {
                            performer.print('\u{FFFD}');
                        }
                    }
                    _ => performer.print('\u{FFFD}'), // 0xC0, 0xC1, 0xF5..=0xFF: invalid lead bytes.
                }
            }
            State::Escape => {
                match byte {
                    0x00..=0x17 | 0x19 | 0x1C..=0x1F => execute = true,
                    0x18 | 0x1A => { execute = true; transition = Some(State::Ground); },
                    0x1B => transition = Some(State::Escape),
                    0x20..=0x2F => { self.push_intermediate(byte); transition = Some(State::EscapeIntermediate); },
                    0x30..=0x4F | 0x51..=0x57 | 0x59 | 0x5A | 0x5C | 0x60..=0x7E => {
                        performer.esc_dispatch(&self.intermediates, self.ignore, byte);
                        transition = Some(State::Ground);
                    }
                    0x50 => transition = Some(State::DcsEntry),
                    0x5B => transition = Some(State::CsiEntry),
                    0x5D => transition = Some(State::OscString),
                    0x58 | 0x5E | 0x5F => transition = Some(State::SosPmApcString),
                    _ => transition = Some(State::Ground),
                }
            }
            State::EscapeIntermediate => {
                match byte {
                    0x00..=0x17 | 0x19 | 0x1C..=0x1F => execute = true,
                    0x18 | 0x1A => { execute = true; transition = Some(State::Ground); },
                    0x1B => transition = Some(State::Escape),
                    0x20..=0x2F => self.push_intermediate(byte),
                    0x30..=0x7E => {
                        performer.esc_dispatch(&self.intermediates, self.ignore, byte);
                        transition = Some(State::Ground);
                    }
                    _ => transition = Some(State::Ground),
                }
            }
            State::CsiEntry => {
                match byte {
                    0x00..=0x17 | 0x19 | 0x1C..=0x1F => execute = true,
                    0x18 | 0x1A => { execute = true; transition = Some(State::Ground); },
                    0x1B => transition = Some(State::Escape),
                    0x20..=0x2F => { self.push_intermediate(byte); transition = Some(State::CsiIntermediate); },
                    0x30..=0x39 => { self.params.push((byte - b'0') as u16); transition = Some(State::CsiParam); },
                    0x3A => { self.new_param(true); transition = Some(State::CsiParam); },
                    0x3B => { self.new_param(false); transition = Some(State::CsiParam); },
                    0x3C..=0x3F => { self.push_intermediate(byte); transition = Some(State::CsiParam); },
                    0x40..=0x7E => {
                        performer.csi_dispatch(&self.params, self.params_sep, &self.intermediates, self.ignore, byte as char);
                        transition = Some(State::Ground);
                    }
                    _ => transition = Some(State::Ground),
                }
            }
            State::CsiParam => {
                match byte {
                    0x00..=0x17 | 0x19 | 0x1C..=0x1F => execute = true,
                    0x18 | 0x1A => { execute = true; transition = Some(State::Ground); },
                    0x1B => transition = Some(State::Escape),
                    0x20..=0x2F => { self.push_intermediate(byte); transition = Some(State::CsiIntermediate); },
                    0x30..=0x39 => self.push_param(byte),
                    0x3A => self.new_param(true),
                    0x3B => self.new_param(false),
                    0x3C..=0x3F => self.ignore = true,
                    0x40..=0x7E => {
                        performer.csi_dispatch(&self.params, self.params_sep, &self.intermediates, self.ignore, byte as char);
                        transition = Some(State::Ground);
                    }
                    _ => transition = Some(State::Ground),
                }
            }
            State::CsiIntermediate => {
                match byte {
                    0x00..=0x17 | 0x19 | 0x1C..=0x1F => execute = true,
                    0x18 | 0x1A => { execute = true; transition = Some(State::Ground); },
                    0x1B => transition = Some(State::Escape),
                    0x20..=0x2F => self.push_intermediate(byte),
                    0x30..=0x3F => self.ignore = true,
                    0x40..=0x7E => {
                        performer.csi_dispatch(&self.params, self.params_sep, &self.intermediates, self.ignore, byte as char);
                        transition = Some(State::Ground);
                    }
                    _ => transition = Some(State::Ground),
                }
            }
            State::DcsEntry => {
                match byte {
                    0x00..=0x17 | 0x19 | 0x1C..=0x1F => transition = None, // ignore
                    0x18 | 0x1A | 0x1B => { transition = Some(State::Escape); },
                    0x20..=0x2F => { self.push_intermediate(byte); transition = Some(State::DcsIntermediate); },
                    0x30..=0x39 => { self.params.push((byte - b'0') as u16); transition = Some(State::DcsParam); },
                    0x3A | 0x3B => { self.new_param(byte == 0x3A); transition = Some(State::DcsParam); },
                    0x3C..=0x3F => { self.push_intermediate(byte); transition = Some(State::DcsParam); },
                    0x40..=0x7E => {
                        performer.hook(&self.params, self.params_sep, &self.intermediates, self.ignore, byte as char);
                        transition = Some(State::DcsPassthrough);
                    }
                    _ => transition = Some(State::Ground),
                }
            }
            State::DcsParam => {
                match byte {
                    0x00..=0x17 | 0x19 | 0x1C..=0x1F => transition = None,
                    0x18 | 0x1A | 0x1B => transition = Some(State::Escape),
                    0x20..=0x2F => { self.push_intermediate(byte); transition = Some(State::DcsIntermediate); },
                    0x30..=0x39 => self.push_param(byte),
                    0x3A => self.new_param(true),
                    0x3B => self.new_param(false),
                    0x3C..=0x3F => self.ignore = true,
                    0x40..=0x7E => {
                        performer.hook(&self.params, self.params_sep, &self.intermediates, self.ignore, byte as char);
                        transition = Some(State::DcsPassthrough);
                    }
                    _ => transition = Some(State::Ground),
                }
            }
            State::DcsIntermediate => {
                match byte {
                    0x00..=0x17 | 0x19 | 0x1C..=0x1F => transition = None,
                    0x18 | 0x1A | 0x1B => transition = Some(State::Escape),
                    0x20..=0x2F => self.push_intermediate(byte),
                    0x30..=0x3F => self.ignore = true,
                    0x40..=0x7E => {
                        performer.hook(&self.params, self.params_sep, &self.intermediates, self.ignore, byte as char);
                        transition = Some(State::DcsPassthrough);
                    }
                    _ => transition = Some(State::Ground),
                }
            }
            State::DcsPassthrough => {
                match byte {
                    0x00..=0x17 | 0x19 | 0x1C..=0x1F => performer.put(byte),
                    0x18 | 0x1A => transition = Some(State::Ground),
                    0x1B => transition = Some(State::Escape),
                    0x20..=0x7E => performer.put(byte),
                    _ => transition = Some(State::Ground),
                }
            }
            State::DcsIgnore => {
                match byte {
                    0x18 | 0x1A => transition = Some(State::Ground),
                    0x1B => transition = Some(State::Escape),
                    _ => transition = None,
                }
            }
            State::OscString => {
                match byte {
                    0x07 => {
                        self.utf8_need = 0;
                        // Dispatch OSC
                        self.dispatch_osc(performer, true);
                        transition = Some(State::Ground);
                    }
                    0x18 | 0x1A => {
                        self.utf8_need = 0;
                        transition = Some(State::Ground);
                    }
                    0x1B => {
                        self.utf8_need = 0;
                        // Normally Esc triggers transition, but let's just handle ST
                        transition = Some(State::Escape);
                    }
                    0x20..=0x7F => {
                        self.utf8_need = 0;
                        self.osc_raw.push(byte);
                    }
                    0xC2..=0xDF => {
                        self.utf8_need = 1;
                        self.osc_raw.push(byte);
                    }
                    0xE0..=0xEF => {
                        self.utf8_need = 2;
                        self.osc_raw.push(byte);
                    }
                    0xF0..=0xF4 => {
                        self.utf8_need = 3;
                        self.osc_raw.push(byte);
                    }
                    0x80..=0xBF => {
                        if self.utf8_need > 0 {
                            self.utf8_need -= 1;
                            self.osc_raw.push(byte);
                        } else if byte == 0x9C {
                            self.dispatch_osc(performer, false);
                            transition = Some(State::Ground);
                        } else {
                            self.osc_raw.push(byte);
                        }
                    }
                    _ => {
                        self.utf8_need = 0;
                        if byte >= 0x80 {
                            self.osc_raw.push(byte);
                        }
                    }
                }
            }
            State::SosPmApcString => {
                match byte {
                    0x18 | 0x1A => {
                        self.utf8_need = 0;
                        transition = Some(State::Ground);
                    }
                    0x1B => {
                        self.utf8_need = 0;
                        transition = Some(State::Escape);
                    }
                    0x20..=0x7F => {
                        self.utf8_need = 0;
                        self.apc_raw.push(byte);
                    }
                    0xC2..=0xDF => {
                        self.utf8_need = 1;
                        self.apc_raw.push(byte);
                    }
                    0xE0..=0xEF => {
                        self.utf8_need = 2;
                        self.apc_raw.push(byte);
                    }
                    0xF0..=0xF4 => {
                        self.utf8_need = 3;
                        self.apc_raw.push(byte);
                    }
                    0x80..=0xBF => {
                        if self.utf8_need > 0 {
                            self.utf8_need -= 1;
                            self.apc_raw.push(byte);
                        } else if byte == 0x9C {
                            self.dispatch_apc(performer);
                            transition = Some(State::Ground);
                        } else {
                            self.apc_raw.push(byte);
                        }
                    }
                    _ => {
                        self.utf8_need = 0;
                        if byte >= 0x80 {
                            self.apc_raw.push(byte);
                        }
                    }
                }
            }
            _ => transition = Some(State::Ground),
        }

        if execute {
            performer.execute(byte);
        }

        if let Some(next_state) = transition {
            // Exit actions
            if self.state == State::DcsPassthrough {
                performer.unhook();
            } else if self.state == State::OscString {
                if next_state == State::Escape {
                    // ST is ESC \. We will parse the '\' in Escape state, but Osc might be dispatched
                    self.dispatch_osc(performer, false);
                }
            } else if self.state == State::SosPmApcString
                && next_state == State::Escape {
                    self.dispatch_apc(performer);
                }
            
            // Enter actions
            if next_state == State::Escape || next_state == State::CsiEntry || next_state == State::DcsEntry || next_state == State::OscString || next_state == State::SosPmApcString {
                self.clear();
            }
            if next_state == State::OscString {
                self.osc_raw.clear();
                self.utf8_need = 0;
            }
            if next_state == State::SosPmApcString {
                self.apc_raw.clear();
                self.utf8_need = 0;
            }

            self.state = next_state;
        }
    }

    /// Advance through a byte slice, batching printable ASCII while the
    /// parser is in its ground state. Escape/control/UTF-8 boundaries still
    /// go through `advance`, so parser state and error handling are identical
    /// to feeding one byte at a time.
    pub fn advance_bytes<P: Perform>(&mut self, performer: &mut P, bytes: &[u8]) {
        let mut offset = 0;
        while offset < bytes.len() {
            if self.state == State::Ground && self.utf8_need == 0 {
                let start = offset;
                offset = Self::printable_ascii_run_end(bytes, offset);
                if offset - start > 1 {
                    performer.print_slice(&bytes[start..offset]);
                    continue;
                }
                offset = start;
            }

            self.advance(performer, bytes[offset]);
            offset += 1;
        }
    }

    #[inline(always)]
    fn printable_ascii_run_end(bytes: &[u8], start: usize) -> usize {
        scan_printable_ascii_run(bytes, start)
    }

    fn dispatch_osc<P: Perform>(&mut self, performer: &mut P, bell: bool) {
        let mut params = Vec::new();
        let mut current_start = 0;
        for (i, &b) in self.osc_raw.iter().enumerate() {
            if b == b';' {
                params.push(&self.osc_raw[current_start..i]);
                current_start = i + 1;
            }
        }
        if current_start <= self.osc_raw.len() {
            params.push(&self.osc_raw[current_start..]);
        }
        performer.osc_dispatch(&params, bell);
    }

    fn dispatch_apc<P: Perform>(&mut self, performer: &mut P) {
        performer.apc_dispatch(&self.apc_raw);
    }
}

#[inline]
fn scan_printable_ascii_run(bytes: &[u8], start: usize) -> usize {
    if start >= bytes.len() {
        return start;
    }

    #[cfg(target_arch = "x86_64")]
    return unsafe { scan_printable_ascii_run_x86_64(bytes, start) };

    #[cfg(target_arch = "aarch64")]
    return scan_printable_ascii_run_aarch64(bytes, start);

    #[cfg(not(any(target_arch = "x86_64", target_arch = "aarch64")))]
    return scan_printable_ascii_run_scalar(bytes, start);
}

#[inline]
fn scan_printable_ascii_run_scalar(bytes: &[u8], mut offset: usize) -> usize {
    while offset < bytes.len() && matches!(bytes[offset], 0x20..=0x7F) {
        offset += 1;
    }
    offset
}

#[cfg(target_arch = "x86_64")]
#[inline]
unsafe fn scan_printable_ascii_run_x86_64(bytes: &[u8], mut offset: usize) -> usize {
    use std::arch::x86_64::{
        __m128i, _mm_cmpeq_epi8, _mm_loadu_si128, _mm_max_epu8, _mm_min_epu8, _mm_movemask_epi8,
        _mm_set1_epi8,
    };

    // SAFETY: SSE2 is part of the x86_64 baseline target feature set.
    let lower = unsafe { _mm_set1_epi8(0x20) };
    let upper = unsafe { _mm_set1_epi8(0x7F) };
    let len = bytes.len();
    let ptr = bytes.as_ptr();

    while offset + 16 <= len {
        // SAFETY: offset + 16 <= len guarantees the unaligned load is in-bounds;
        // all intrinsics used here require only baseline SSE2 on x86_64.
        let chunk = unsafe { _mm_loadu_si128(ptr.add(offset) as *const __m128i) };
        let run_high = unsafe { _mm_max_epu8(chunk, lower) };
        let run_in_range = unsafe {
            _mm_cmpeq_epi8(_mm_min_epu8(run_high, upper), chunk)
        };
        let mask = unsafe { _mm_movemask_epi8(run_in_range) as u32 };
        if mask == 0xFFFF {
            offset += 16;
            continue;
        }

        let first_invalid = (!mask & 0xFFFF).trailing_zeros() as usize;
        return offset + first_invalid;
    }

    scan_printable_ascii_run_scalar(bytes, offset)
}

#[cfg(target_arch = "aarch64")]
#[inline]
fn scan_printable_ascii_run_aarch64(bytes: &[u8], mut offset: usize) -> usize {
    use std::arch::aarch64::{
        uint8x16_t, vceqq_u8, vdupq_n_u8, vmaxq_u8, vld1q_u8, vminq_u8, vst1q_u8,
    };

    let lower = unsafe { vdupq_n_u8(0x20) };
    let upper = unsafe { vdupq_n_u8(0x7F) };
    let len = bytes.len();
    let mut block = [0u8; 16];
    let ptr = bytes.as_ptr();

    while offset + 16 <= len {
        // SAFETY: offset + 16 <= len guarantees this unaligned 16-byte load is in-bounds.
        let chunk: uint8x16_t = unsafe { vld1q_u8(ptr.add(offset)) };
        let run_high = unsafe { vmaxq_u8(chunk, lower) };
        let run_in_range = unsafe { vceqq_u8(chunk, vminq_u8(run_high, upper)) };

        // SAFETY: `block` is a valid 16-byte destination; this is only temporary stack storage.
        unsafe { vst1q_u8(block.as_mut_ptr(), run_in_range) };
        for (index, byte) in block.iter().enumerate() {
            if *byte == 0 {
                return offset + index;
            }
        }

        offset += 16;
    }

    scan_printable_ascii_run_scalar(bytes, offset)
}

#[cfg(test)]
mod tests;
