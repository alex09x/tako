#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TitleStack {
    stack: Vec<String>,
}

impl TitleStack {
    pub fn new() -> Self {
        Self {
            stack: Vec::with_capacity(10),
        }
    }

    /// Heap this stack holds, by capacity: the spine plus each title's own
    /// allocation.
    pub fn retained_capacity_bytes(&self) -> u64 {
        let mut total = (self.stack.capacity() as u64)
            .saturating_mul(std::mem::size_of::<String>() as u64);
        for item in &self.stack {
            total = total.saturating_add(item.capacity() as u64);
        }
        total
    }

    pub fn push(&mut self, title: &str) {
        if self.stack.len() >= 10 {
            self.stack.remove(0);
        }
        self.stack.push(title.to_string());
    }

    pub fn pop(&mut self) -> Option<String> {
        self.stack.pop()
    }

    pub fn len(&self) -> usize {
        self.stack.len()
    }

    pub fn is_empty(&self) -> bool {
        self.stack.is_empty()
    }

    pub fn items(&self) -> &[String] {
        &self.stack
    }

    pub fn from_items(stack: Vec<String>) -> Self {
        Self { stack }
    }
}

impl Default for TitleStack {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_new_is_empty() {
        let mut ts = TitleStack::new();
        assert!(ts.is_empty());
        assert_eq!(ts.len(), 0);
        assert_eq!(ts.pop(), None);

        let default_ts = TitleStack::default();
        assert!(default_ts.is_empty());
        assert_eq!(default_ts.len(), 0);
    }

    #[test]
    fn test_push_pop_round_trip() {
        let mut ts = TitleStack::new();
        ts.push("hello world");
        assert!(!ts.is_empty());
        assert_eq!(ts.len(), 1);
        assert_eq!(ts.pop(), Some("hello world".to_string()));
        assert!(ts.is_empty());
        assert_eq!(ts.len(), 0);
    }

    #[test]
    fn test_multiple_pushes_lifo() {
        let mut ts = TitleStack::new();
        ts.push("first");
        ts.push("second");
        ts.push("third");
        assert_eq!(ts.len(), 3);
        assert_eq!(ts.pop(), Some("third".to_string()));
        assert_eq!(ts.pop(), Some("second".to_string()));
        assert_eq!(ts.pop(), Some("first".to_string()));
        assert_eq!(ts.pop(), None);
    }

    #[test]
    fn test_push_max_capacity_drops_oldest() {
        let mut ts = TitleStack::new();
        for i in 1..=11 {
            ts.push(&format!("title{}", i));
        }
        assert_eq!(ts.len(), 10);
        // Verify popping remaining 10 titles in LIFO order (11 down to 2)
        for i in (2..=11).rev() {
            assert_eq!(ts.pop(), Some(format!("title{}", i)));
        }
        // Oldest (1st pushed, "title1") was dropped so pop returns None
        assert_eq!(ts.pop(), None);
    }

    #[test]
    fn test_pop_more_times_than_pushed() {
        let mut ts = TitleStack::new();
        ts.push("one");
        ts.push("two");
        assert_eq!(ts.pop(), Some("two".to_string()));
        assert_eq!(ts.pop(), Some("one".to_string()));
        assert_eq!(ts.pop(), None);
        assert_eq!(ts.pop(), None);
        assert_eq!(ts.pop(), None);
        assert!(ts.is_empty());
        assert_eq!(ts.len(), 0);
    }
}
