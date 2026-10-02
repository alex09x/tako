//! What the shell said about each command it ran (OSC 133), kept so a search
//! hit can say which command printed it.
//!
//! A record opens at `133;C` (output starts) and closes at `133;D`, or is
//! abandoned when a new prompt or command starts without one. Which rows a
//! command printed is not kept here: each row carries its owner (see
//! [`crate::grid::RowOwner`]), and a row naming an id this table no longer
//! has simply belongs to no command. Ids are never reused by a terminal --
//! not after a reset either -- so a stale id can only miss, never name the
//! wrong command.

use std::collections::VecDeque;

/// Most records kept; the oldest finished ones go first.
pub const MAX_COMMAND_RECORDS: usize = 10_000;
/// Most text (cwd + input) kept across all records, in bytes.
pub const MAX_COMMAND_TEXT_BYTES: usize = 2 << 20;
/// Longest working directory kept; a longer one is not kept at all.
pub const MAX_CWD_BYTES: usize = 1024;
/// Most characters of a command line kept.
pub const MAX_INPUT_CHARS: usize = 512;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandStatus {
    /// Output started and the shell has not said it ended.
    Running,
    /// `133;D`, with the exit code when the shell sent one. No code is not
    /// success.
    Completed(Option<i32>),
    /// A new prompt or command started without a `133;D` for this one.
    Abandoned,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandRecord {
    pub id: u64,
    pub status: CommandStatus,
    /// The last OSC 7 report before the command started.
    pub cwd: Option<String>,
    /// The command line as the screen showed it between `133;B` and
    /// `133;C`; `None` when there was no `B` or the text was gone.
    pub input: Option<String>,
    /// Whether `input` was cut at [`MAX_INPUT_CHARS`].
    pub input_truncated: bool,
    /// When the command started, from the host (unix ms).
    pub started_at_ms: Option<u64>,
}

impl CommandRecord {
    fn text_bytes(&self) -> usize {
        self.cwd.as_ref().map_or(0, String::len) + self.input.as_ref().map_or(0, String::len)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandLog {
    /// Ascending by id.
    records: VecDeque<CommandRecord>,
    /// The id the next command gets; `None` once ids ran out.
    next_id: Option<u64>,
    /// The command whose output is being written, if any.
    running: Option<u64>,
    text_bytes: usize,
    /// Prune once the table grows to this many records again.
    prune_at: usize,
}

/// The table is never pruned below this many records: a sweep reads every
/// retained row, so it runs only after the table has doubled.
const PRUNE_FLOOR: usize = 64;

impl Default for CommandLog {
    fn default() -> Self {
        Self { records: VecDeque::new(), next_id: Some(1), running: None, text_bytes: 0, prune_at: PRUNE_FLOOR }
    }
}

impl CommandLog {
    pub fn get(&self, id: u64) -> Option<&CommandRecord> {
        let i = self.records.binary_search_by_key(&id, |r| r.id).ok()?;
        self.records.get(i)
    }

    fn get_mut(&mut self, id: u64) -> Option<&mut CommandRecord> {
        let i = self.records.binary_search_by_key(&id, |r| r.id).ok()?;
        self.records.get_mut(i)
    }

    pub fn running(&self) -> Option<u64> {
        self.running
    }

    pub fn next_id(&self) -> Option<u64> {
        self.next_id
    }

    pub fn records(&self) -> impl ExactSizeIterator<Item = &CommandRecord> + DoubleEndedIterator {
        self.records.iter()
    }

    /// Open a record for a command whose output starts now, abandoning one
    /// still running. `None` when ids ran out: nothing more is recorded.
    pub fn start(&mut self, cwd: Option<String>, input: Option<String>, truncated: bool) -> Option<u64> {
        self.abandon_running();
        let id = self.next_id?;
        self.next_id = id.checked_add(1);
        let record = CommandRecord {
            id,
            status: CommandStatus::Running,
            cwd,
            input,
            input_truncated: truncated,
            started_at_ms: None,
        };
        self.text_bytes += record.text_bytes();
        self.records.push_back(record);
        self.running = Some(id);
        self.enforce_limits();
        Some(id)
    }

    /// Close the running command; returns its id.
    pub fn finish(&mut self, exit_code: Option<i32>) -> Option<u64> {
        let id = self.running.take()?;
        if let Some(r) = self.get_mut(id) {
            r.status = CommandStatus::Completed(exit_code);
        }
        Some(id)
    }

    pub fn abandon_running(&mut self) {
        if let Some(id) = self.running.take()
            && let Some(r) = self.get_mut(id)
        {
            r.status = CommandStatus::Abandoned;
        }
    }

    /// Give command `id` its start time. Only the first time counts; false
    /// when there is no such record or it already has one.
    pub fn set_started_at(&mut self, id: u64, unix_ms: u64) -> bool {
        match self.get_mut(id) {
            Some(r) if r.started_at_ms.is_none() => {
                r.started_at_ms = Some(unix_ms);
                true
            }
            _ => false,
        }
    }

    /// Whether enough records were added since the last sweep for another.
    pub(crate) fn prune_due(&self) -> bool {
        self.records.len() >= self.prune_at
    }

    /// Forget every finished record no retained row names: its output is
    /// gone, so nothing could be grouped under it.
    pub(crate) fn prune(&mut self, live: &std::collections::HashSet<u64>) {
        let running = self.running;
        let mut freed = 0;
        self.records.retain(|r| {
            let keep = Some(r.id) == running || live.contains(&r.id);
            if !keep {
                freed += r.text_bytes();
            }
            keep
        });
        self.text_bytes -= freed;
        self.prune_at = (self.records.len() * 2).max(PRUNE_FLOOR);
    }

    /// Forget every record (reset). Ids keep counting.
    pub fn clear(&mut self) {
        self.records.clear();
        self.running = None;
        self.text_bytes = 0;
    }

    fn enforce_limits(&mut self) {
        while self.records.len() > MAX_COMMAND_RECORDS || self.text_bytes > MAX_COMMAND_TEXT_BYTES {
            let Some(i) = self.records.iter().position(|r| Some(r.id) != self.running) else {
                break;
            };
            let gone = self.records.remove(i).unwrap();
            self.text_bytes -= gone.text_bytes();
        }
    }

    /// Heap held, by capacity.
    pub fn heap_bytes(&self) -> u64 {
        let spine = self.records.capacity() * std::mem::size_of::<CommandRecord>();
        let text: usize = self
            .records
            .iter()
            .map(|r| {
                r.cwd.as_ref().map_or(0, String::capacity)
                    + r.input.as_ref().map_or(0, String::capacity)
            })
            .sum();
        (spine + text) as u64
    }

    /// Rebuild from checkpointed parts, rejecting anything inconsistent:
    /// ids strictly ascending and below `next_id`, text within the limits,
    /// at most one `Running` record and only as `running`.
    pub(crate) fn from_parts(
        records: Vec<CommandRecord>,
        next_id: Option<u64>,
        running: Option<u64>,
    ) -> Result<Self, &'static str> {
        if records.len() > MAX_COMMAND_RECORDS {
            return Err("too many command records");
        }
        let mut text_bytes = 0usize;
        let mut last: Option<u64> = None;
        for r in &records {
            if r.id == 0 || last.is_some_and(|l| r.id <= l) {
                return Err("command ids not ascending");
            }
            if next_id.is_some_and(|n| r.id >= n) {
                return Err("command id not below next id");
            }
            if r.cwd.as_ref().is_some_and(|c| c.len() > MAX_CWD_BYTES)
                || r.input.as_ref().is_some_and(|i| i.chars().count() > MAX_INPUT_CHARS)
            {
                return Err("command text too long");
            }
            let running_here = r.status == CommandStatus::Running;
            if running_here != (running == Some(r.id)) {
                return Err("running command inconsistent");
            }
            text_bytes = text_bytes.checked_add(r.text_bytes()).ok_or("command text overflow")?;
            last = Some(r.id);
        }
        if text_bytes > MAX_COMMAND_TEXT_BYTES {
            return Err("command text too long");
        }
        if let Some(id) = running
            && !records.iter().any(|r| r.id == id)
        {
            return Err("running command missing");
        }
        if next_id == Some(0) {
            return Err("next command id is zero");
        }
        Ok(Self { records: records.into(), next_id, running, text_bytes, prune_at: PRUNE_FLOOR })
    }
}
