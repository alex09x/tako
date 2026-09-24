#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabStops {
    cols: usize,
    stops: Vec<bool>,
}

impl TabStops {
    pub fn new(cols: usize) -> Self {
        let mut stops = vec![false; cols];
        for col in 1..cols {
            if col % 8 == 0 {
                stops[col] = true;
            }
        }
        Self { cols, stops }
    }

    /// Heap this bitset holds, by capacity.
    pub fn retained_capacity_bytes(&self) -> u64 {
        self.stops.capacity() as u64
    }

    pub fn stops(&self) -> &[bool] {
        &self.stops
    }

    pub fn from_raw(cols: usize, mut stops: Vec<bool>) -> Self {
        if stops.len() < cols {
            stops.resize(cols, false);
        } else if stops.len() > cols {
            stops.truncate(cols);
        }
        Self { cols, stops }
    }

    pub fn set(&mut self, col: usize) {
        if col < self.cols {
            self.stops[col] = true;
        }
    }

    pub fn clear(&mut self, col: usize) {
        if col < self.cols {
            self.stops[col] = false;
        }
    }

    pub fn clear_all(&mut self) {
        self.stops.fill(false);
    }

    pub fn next_stop(&self, from_col: usize) -> usize {
        if self.cols == 0 {
            return from_col;
        }
        let start = from_col.saturating_add(1);
        if start < self.cols {
            for col in start..self.cols {
                if self.stops[col] {
                    return col;
                }
            }
        }
        self.cols - 1
    }

    pub fn prev_stop(&self, from_col: usize) -> usize {
        if from_col == 0 || self.cols == 0 {
            return 0;
        }
        let max_search = (from_col - 1).min(self.cols - 1);
        for col in (0..=max_search).rev() {
            if self.stops[col] {
                return col;
            }
        }
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_stops_new_80() {
        let ts = TabStops::new(80);
        for col in 0..80 {
            let is_stop = col > 0 && col % 8 == 0;
            if is_stop {
                assert_eq!(ts.next_stop(col - 1), col);
                assert_eq!(ts.prev_stop(col + 1), col);
            }
        }
        // Col 0 must not be a stop
        assert_eq!(ts.prev_stop(1), 0);
    }

    #[test]
    fn test_next_and_prev_stop_positions() {
        let ts = TabStops::new(80);

        // Before first stop (stops are at 8, 16, 24...)
        assert_eq!(ts.next_stop(0), 8);
        assert_eq!(ts.next_stop(7), 8);
        assert_eq!(ts.prev_stop(0), 0);
        assert_eq!(ts.prev_stop(5), 0);
        assert_eq!(ts.prev_stop(8), 0);

        // Between stops
        assert_eq!(ts.next_stop(8), 16);
        assert_eq!(ts.next_stop(12), 16);
        assert_eq!(ts.prev_stop(9), 8);
        assert_eq!(ts.prev_stop(16), 8);

        // After last stop (72 is the last stop < 80)
        assert_eq!(ts.next_stop(72), 79);
        assert_eq!(ts.next_stop(75), 79);
        assert_eq!(ts.next_stop(79), 79);
        assert_eq!(ts.next_stop(100), 79);

        assert_eq!(ts.prev_stop(79), 72);
        assert_eq!(ts.prev_stop(100), 72);
    }

    #[test]
    fn test_set_clear_clear_all_mutation() {
        let mut ts = TabStops::new(80);

        // Set a custom stop at col 5
        ts.set(5);
        assert_eq!(ts.next_stop(0), 5);
        assert_eq!(ts.prev_stop(6), 5);

        // Clear stop at col 8
        ts.clear(8);
        assert_eq!(ts.next_stop(5), 16);
        assert_eq!(ts.prev_stop(16), 5);

        // Clear all stops
        ts.clear_all();
        assert_eq!(ts.next_stop(0), 79);
        assert_eq!(ts.prev_stop(50), 0);
    }

    #[test]
    fn test_clear_all_followed_by_next_stop() {
        let mut ts = TabStops::new(80);
        ts.clear_all();

        assert_eq!(ts.next_stop(0), 79);
        assert_eq!(ts.next_stop(10), 79);
        assert_eq!(ts.next_stop(78), 79);
        assert_eq!(ts.next_stop(79), 79);
    }

    #[test]
    fn test_out_of_range_set_clear_no_ops() {
        let mut ts = TabStops::new(80);

        // Out-of-range set and clear should be silent no-ops
        ts.set(100);
        ts.set(80);
        ts.clear(100);
        ts.clear(80);

        assert_eq!(ts.next_stop(72), 79);
        assert_eq!(ts.prev_stop(80), 72);
    }

    #[test]
    fn test_zero_cols() {
        let mut ts = TabStops::new(0);

        assert_eq!(ts.next_stop(0), 0);
        assert_eq!(ts.next_stop(5), 5);
        assert_eq!(ts.prev_stop(0), 0);
        assert_eq!(ts.prev_stop(5), 0);

        ts.set(0);
        ts.set(5);
        ts.clear(0);
        ts.clear(5);
        ts.clear_all();
    }
}
