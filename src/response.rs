#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResponseQueue {
    buffer: Vec<u8>,
}

impl ResponseQueue {
    pub fn new() -> Self {
        Self {
            buffer: Vec::new(),
        }
    }

    /// Heap this queue holds, by capacity. `take` swaps the buffer out, but a
    /// drain that only clears it keeps the allocation.
    pub fn retained_capacity_bytes(&self) -> u64 {
        self.buffer.capacity() as u64
    }

    pub fn push_str(&mut self, s: &str) {
        self.buffer.extend_from_slice(s.as_bytes());
    }

    pub fn take(&mut self) -> Vec<u8> {
        std::mem::take(&mut self.buffer)
    }

    pub fn is_empty(&self) -> bool {
        self.buffer.is_empty()
    }
}

impl Default for ResponseQueue {
    fn default() -> Self {
        Self::new()
    }
}

pub fn da1_response() -> String {
    "\x1b[?62;22c".to_string()
}

pub fn da2_response() -> String {
    "\x1b[>1;0;0c".to_string()
}

pub fn cursor_position_report(row1: usize, col1: usize) -> String {
    format!("\x1b[{row1};{col1}R")
}

pub fn device_status_ok() -> String {
    "\x1b[0n".to_string()
}

pub fn xtversion_response(name: &str) -> String {
    format!("\x1bP>|{}\x1b\\", name)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_da1_response() {
        assert_eq!(da1_response(), "\x1b[?62;22c");
    }

    #[test]
    fn test_da2_response() {
        assert_eq!(da2_response(), "\x1b[>1;0;0c");
    }

    #[test]
    fn test_cursor_position_report() {
        assert_eq!(cursor_position_report(1, 1), "\x1b[1;1R");
        assert_eq!(cursor_position_report(24, 80), "\x1b[24;80R");
    }

    #[test]
    fn test_device_status_ok() {
        assert_eq!(device_status_ok(), "\x1b[0n");
    }

    #[test]
    fn test_xtversion_response() {
        assert_eq!(
            xtversion_response("tako-core 0.1.0"),
            "\x1bP>|tako-core 0.1.0\x1b\\"
        );
    }

    #[test]
    fn test_response_queue_initial_state() {
        let mut queue = ResponseQueue::new();
        assert!(queue.is_empty());
        assert_eq!(queue.take(), Vec::<u8>::new());
    }

    #[test]
    fn test_response_queue_default() {
        let mut queue = ResponseQueue::default();
        assert!(queue.is_empty());
        assert_eq!(queue.take(), Vec::<u8>::new());
    }

    #[test]
    fn test_response_queue_push_and_take() {
        let mut queue = ResponseQueue::new();
        queue.push_str("hello");
        assert!(!queue.is_empty());
        assert_eq!(queue.take(), b"hello");
        assert!(queue.is_empty());
    }

    #[test]
    fn test_response_queue_multiple_push_str() {
        let mut queue = ResponseQueue::new();
        queue.push_str("foo");
        queue.push_str("bar");
        queue.push_str("baz");
        assert_eq!(queue.take(), b"foobarbaz");
        assert!(queue.is_empty());
    }
}
