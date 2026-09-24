// Grapheme clusters: the table of each cell's extra codepoints, and the
// UAX #29 rules for when a codepoint continues a cluster.

use std::collections::HashMap;

use unicode_segmentation::GraphemeCursor;
use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

/// Ids are `u16` so a [`super::Cell`] keeps its size: the id fits in padding
/// the cell already had.
const MAX_ENTRIES: usize = u16::MAX as usize;

/// Table size at which the first collection runs.
const FIRST_COLLECTION: usize = 1024;

/// Interns refused without collecting once a collection found every id live.
const FULL_BACKOFF: u32 = 4096;

/// Longest run of extra codepoints a cell keeps, in UTF-8 bytes. Further
/// codepoints of the same cluster still take no column; their text is
/// dropped, so a stream of stacked marks cannot grow one cell without bound.
pub(crate) const MAX_EXTRA_BYTES: usize = 256;

/// The codepoints that follow each multi-codepoint cell's `char`, interned per
/// grid and addressed by `Cell::grapheme`.
///
/// Cells are `Copy` and move freely between rows, scrollback and reflowed
/// lines, so entries are not reference counted: an entry is reclaimed by a
/// collection that finds no cell in the grid or its scrollback naming it.
#[derive(Clone, Default)]
pub(crate) struct GraphemeTable {
    /// `entries[id - 1]`; `None` is a free slot.
    entries: Vec<Option<Entry>>,
    narrow: HashMap<Box<str>, u16>,
    wide: HashMap<Box<str>, u16>,
    free: Vec<u16>,
    collect_at: usize,
    backoff: u32,
}

#[derive(Clone)]
struct Entry {
    text: Box<str>,
    wide: bool,
}

impl GraphemeTable {
    #[inline]
    fn entry(&self, id: u16) -> Option<&Entry> {
        self.entries.get((id as usize).checked_sub(1)?)?.as_ref()
    }

    /// The extra codepoints of `id`, or `""` for 0 or a stale id.
    #[inline]
    pub(crate) fn text(&self, id: u16) -> &str {
        self.entry(id).map_or("", |entry| &entry.text)
    }

    /// Whether `id` was interned as a double-width cluster.
    #[inline]
    pub(crate) fn is_wide(&self, id: u16) -> Option<bool> {
        self.entry(id).map(|entry| entry.wide)
    }

    fn map(&self, wide: bool) -> &HashMap<Box<str>, u16> {
        if wide { &self.wide } else { &self.narrow }
    }

    pub(crate) fn find(&self, text: &str, wide: bool) -> Option<u16> {
        self.map(wide).get(text).copied()
    }

    /// Whether adding an entry should first reclaim unused ones. Counts the
    /// refusal against the backoff when the table was found full before.
    pub(crate) fn wants_collection(&mut self) -> bool {
        if !self.free.is_empty() {
            return false;
        }
        let threshold = if self.collect_at == 0 { FIRST_COLLECTION } else { self.collect_at };
        if self.entries.len() < threshold.min(MAX_ENTRIES) {
            return false;
        }
        if self.backoff > 0 {
            self.backoff -= 1;
            return false;
        }
        true
    }

    /// Adds an entry; `None` when every id is in use.
    pub(crate) fn insert(&mut self, text: &str, wide: bool) -> Option<u16> {
        let id = match self.free.pop() {
            Some(id) => id,
            None if self.entries.len() < MAX_ENTRIES => {
                self.entries.push(None);
                self.entries.len() as u16
            }
            None => return None,
        };
        let text: Box<str> = text.into();
        if wide {
            self.wide.insert(text.clone(), id);
        } else {
            self.narrow.insert(text.clone(), id);
        }
        self.entries[id as usize - 1] = Some(Entry { text, wide });
        Some(id)
    }

    /// Frees every entry whose bit is clear in `live` (indexed by id).
    pub(crate) fn sweep(&mut self, live: &[u64]) {
        for index in 0..self.entries.len() {
            let id = index + 1;
            if live[id / 64] & (1 << (id % 64)) != 0 {
                continue;
            }
            if let Some(entry) = self.entries[index].take() {
                if entry.wide {
                    self.wide.remove(&entry.text);
                } else {
                    self.narrow.remove(&entry.text);
                }
                self.free.push(id as u16);
            }
        }
        let live_count = self.entries.len() - self.free.len();
        self.collect_at = (live_count * 2).max(FIRST_COLLECTION);
        if self.free.is_empty() && self.entries.len() >= MAX_ENTRIES {
            self.backoff = FULL_BACKOFF;
        }
    }

    /// Entries in use.
    #[cfg(test)]
    pub(crate) fn live(&self) -> usize {
        self.entries.len() - self.free.len()
    }

    /// A zeroed bitset with one bit per possible id.
    pub(crate) fn live_set() -> Vec<u64> {
        vec![0; MAX_ENTRIES / 64 + 1]
    }

    pub(crate) fn heap_bytes(&self) -> u64 {
        let text: usize = self
            .entries
            .iter()
            .flatten()
            .map(|entry| entry.text.len())
            .sum();
        let slots = self.entries.capacity() * std::mem::size_of::<Option<Entry>>();
        let maps = (self.narrow.capacity() + self.wide.capacity())
            * (std::mem::size_of::<Box<str>>() + std::mem::size_of::<u16>() + 1);
        // Keys and entries each own a copy of the text.
        (slots + maps + self.free.capacity() * 2 + text * 2) as u64
    }
}

/// Codepoints whose grapheme break property is Other throughout: between two
/// of them there is always a cluster boundary, which spares ordinary text
/// the full UAX #29 check.
#[inline]
pub(crate) fn always_breaks(c: char) -> bool {
    matches!(c,
        '\u{20}'..='\u{7E}'
        | '\u{A0}'..='\u{AC}'
        | '\u{AE}'..='\u{2FF}'
        | '\u{370}'..='\u{482}'
        | '\u{48A}'..='\u{52F}'
        | '\u{2010}'..='\u{2027}'
        | '\u{2030}'..='\u{205F}'
        | '\u{2070}'..='\u{20CF}'
        | '\u{2100}'..='\u{2BFF}'
        | '\u{3041}'..='\u{3096}'
        | '\u{30A1}'..='\u{30FA}'
        | '\u{3400}'..='\u{4DBF}'
        | '\u{4E00}'..='\u{9FFF}'
        | '\u{AC00}'..='\u{D7A3}'
        | '\u{F900}'..='\u{FAFF}'
        | '\u{FF01}'..='\u{FF9D}'
        | '\u{1F300}'..='\u{1F3FA}'
        | '\u{1F400}'..='\u{1F64F}'
        | '\u{1F680}'..='\u{1F6FF}'
        | '\u{1F900}'..='\u{1F9FF}'
        | '\u{20000}'..='\u{3FFFD}')
}

/// Whether `c` continues the grapheme cluster `base` + `extra` (UAX #29,
/// extended clusters) rather than starting a new one.
pub(crate) fn continues_cluster(base: char, extra: &str, c: char) -> bool {
    // UAX #29 breaks between any two such codepoints; everything else --
    // marks, joiners, Hangul jamo, regional indicators -- gets the full rules.
    if extra.is_empty() && always_breaks(base) && always_breaks(c) {
        return false;
    }
    with_cluster(base, extra, Some(c), |text| {
        let offset = text.len() - c.len_utf8();
        let mut cursor = GraphemeCursor::new(offset, text.len(), true);
        !cursor.is_boundary(text, 0).unwrap_or(true)
    })
}

/// Codepoints that make a cluster an emoji sequence whose width is not its
/// first codepoint's: presentation selectors, joiners, skin tones and
/// regional indicators.
#[inline]
fn is_presentation_component(c: char) -> bool {
    matches!(c,
        '\u{FE0E}' | '\u{FE0F}' | '\u{200D}'
        | '\u{1F1E6}'..='\u{1F1FF}'
        | '\u{1F3FB}'..='\u{1F3FF}')
}

/// Whether a cluster takes two columns under grapheme-width-method=unicode:
/// its first codepoint's width, except that an emoji sequence (VS16
/// presentation, ZWJ sequence, skin tone, flag) is two columns and VS15 text
/// presentation is one.
pub(crate) fn unicode_cluster_is_wide(base: char, extra: &str) -> bool {
    if !extra.chars().any(is_presentation_component) {
        return base.width().unwrap_or(1) >= 2;
    }
    with_cluster(base, extra, None, |text| text.width() >= 2)
}

/// Runs `f` over `base` + `extra` (+ `last`) without allocating for the
/// common short cluster.
fn with_cluster<R>(base: char, extra: &str, last: Option<char>, f: impl FnOnce(&str) -> R) -> R {
    let len = base.len_utf8() + extra.len() + last.map_or(0, char::len_utf8);
    let mut stack = [0u8; 64];
    if len <= stack.len() {
        let mut at = base.encode_utf8(&mut stack).len();
        stack[at..at + extra.len()].copy_from_slice(extra.as_bytes());
        at += extra.len();
        if let Some(last) = last {
            last.encode_utf8(&mut stack[at..]);
        }
        let text = std::str::from_utf8(&stack[..len]).unwrap_or_default();
        return f(text);
    }
    let mut text = String::with_capacity(len);
    text.push(base);
    text.push_str(extra);
    text.extend(last);
    f(&text)
}
