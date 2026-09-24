bitflags::bitflags! {
    #[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
    pub struct KittyFlags: u8 {
        const DISAMBIGUATE_ESCAPE_CODES  = 0b00001;
        const REPORT_EVENT_TYPES         = 0b00010;
        const REPORT_ALTERNATE_KEYS      = 0b00100;
        const REPORT_ALL_KEYS_AS_ESCAPES = 0b01000;
        const REPORT_ASSOCIATED_TEXT     = 0b10000;
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KittyKeyboardState {
    stack: Vec<KittyFlags>,
}

impl KittyKeyboardState {
    pub fn new() -> Self {
        Self {
            stack: Vec::new(),
        }
    }

    /// Heap this stack holds, by capacity.
    pub fn retained_capacity_bytes(&self) -> u64 {
        (self.stack.capacity() as u64).saturating_mul(std::mem::size_of::<KittyFlags>() as u64)
    }

    pub fn current(&self) -> KittyFlags {
        self.stack.last().copied().unwrap_or_else(KittyFlags::empty)
    }

    pub fn push(&mut self, flags: KittyFlags) {
        if self.stack.len() >= 8 {
            self.stack.remove(0);
        }
        self.stack.push(flags);
    }

    pub fn pop(&mut self, n: usize) {
        if n >= self.stack.len() {
            self.stack.clear();
        } else {
            self.stack.truncate(self.stack.len() - n);
        }
    }

    pub fn set(&mut self, flags: KittyFlags) {
        if let Some(last) = self.stack.last_mut() {
            *last = flags;
        } else {
            self.stack.push(flags);
        }
    }

    pub fn query_response(&self) -> String {
        format!("\x1b[?{}u", self.current().bits())
    }

    pub fn stack(&self) -> &[KittyFlags] {
        &self.stack
    }

    pub fn from_stack(stack: Vec<KittyFlags>) -> Self {
        Self { stack }
    }
}

impl Default for KittyKeyboardState {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_state() {
        let state = KittyKeyboardState::new();
        assert_eq!(state.current(), KittyFlags::empty());
        assert_eq!(state.query_response(), "\x1b[?0u");
    }

    #[test]
    fn test_push_and_current() {
        let mut state = KittyKeyboardState::new();
        let flags = KittyFlags::DISAMBIGUATE_ESCAPE_CODES | KittyFlags::REPORT_ALTERNATE_KEYS;
        state.push(flags);
        assert_eq!(state.current(), flags);
        assert_eq!(state.query_response(), "\x1b[?5u");
    }

    #[test]
    fn test_multiple_pushes() {
        let mut state = KittyKeyboardState::new();
        let f1 = KittyFlags::DISAMBIGUATE_ESCAPE_CODES;
        let f2 = KittyFlags::REPORT_EVENT_TYPES;
        let f3 = KittyFlags::REPORT_ASSOCIATED_TEXT;
        state.push(f1);
        assert_eq!(state.current(), f1);
        state.push(f2);
        assert_eq!(state.current(), f2);
        state.push(f3);
        assert_eq!(state.current(), f3);
    }

    #[test]
    fn test_pop_one() {
        let mut state = KittyKeyboardState::new();
        let f1 = KittyFlags::DISAMBIGUATE_ESCAPE_CODES;
        let f2 = KittyFlags::REPORT_EVENT_TYPES;
        state.push(f1);
        state.push(f2);
        assert_eq!(state.current(), f2);
        state.pop(1);
        assert_eq!(state.current(), f1);
    }

    #[test]
    fn test_pop_larger_than_depth() {
        let mut state = KittyKeyboardState::new();
        state.push(KittyFlags::DISAMBIGUATE_ESCAPE_CODES);
        state.push(KittyFlags::REPORT_EVENT_TYPES);
        state.pop(100);
        assert_eq!(state.current(), KittyFlags::empty());
        assert_eq!(state.query_response(), "\x1b[?0u");
    }

    #[test]
    fn test_push_ninth_frame_drops_oldest() {
        let mut state = KittyKeyboardState::new();
        for i in 1..=8 {
            let flags = KittyFlags::from_bits_truncate(i as u8);
            state.push(flags);
        }
        assert_eq!(state.current(), KittyFlags::from_bits_truncate(8));

        let f9 = KittyFlags::REPORT_ASSOCIATED_TEXT;
        state.push(f9);
        assert_eq!(state.current(), f9);
        assert_eq!(state.stack.len(), 8);

        state.pop(7);
        assert_eq!(state.current(), KittyFlags::from_bits_truncate(2));
        state.pop(1);
        assert_eq!(state.current(), KittyFlags::empty());
    }

    #[test]
    fn test_set_on_empty_stack() {
        let mut state = KittyKeyboardState::new();
        let flags = KittyFlags::REPORT_ALL_KEYS_AS_ESCAPES;
        state.set(flags);
        assert_eq!(state.current(), flags);
        assert_eq!(state.stack.len(), 1);
    }

    #[test]
    fn test_set_on_non_empty_stack() {
        let mut state = KittyKeyboardState::new();
        let f1 = KittyFlags::DISAMBIGUATE_ESCAPE_CODES;
        let f2 = KittyFlags::REPORT_EVENT_TYPES;
        let f3 = KittyFlags::REPORT_ASSOCIATED_TEXT;
        state.push(f1);
        state.push(f2);
        state.set(f3);
        assert_eq!(state.current(), f3);
        assert_eq!(state.stack.len(), 2);
        state.pop(1);
        assert_eq!(state.current(), f1);
    }
}
