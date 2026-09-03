//! A bounded scrollback buffer.
//!
//! The bridge keeps the authoritative scrollback server-side so a phone that
//! attaches mid-session gets a screen replay before the live stream starts
//! (`docs/WINDOWS_SUPPORT_PLAN.md` §3.1). Ring semantics keep memory flat over
//! a long-running agent session.

use std::collections::VecDeque;

use crate::vt::AnsiFilter;

/// Lines of terminal output, capped at a fixed count.
#[derive(Debug)]
pub struct Scrollback {
    lines: VecDeque<String>,
    /// The line still being written, i.e. everything after the last newline.
    pending: String,
    capacity: usize,
    filter: AnsiFilter,
    /// A CR is buffered until the next character decides whether it was a
    /// bare CR (rewind) or the first half of a CRLF (newline).
    saw_cr: bool,
    /// Total lines ever completed, including evicted ones. Lets a client detect
    /// that it missed history rather than silently seeing a shorter buffer.
    total_lines: u64,
}

impl Scrollback {
    /// `capacity` is the maximum number of retained completed lines. A zero
    /// capacity is promoted to 1 so the buffer always has somewhere to put a
    /// finished line.
    pub fn new(capacity: usize) -> Self {
        Self {
            lines: VecDeque::new(),
            pending: String::new(),
            capacity: capacity.max(1),
            filter: AnsiFilter::new(),
            saw_cr: false,
            total_lines: 0,
        }
    }

    /// Feeds raw PTY bytes. Escape sequences are stripped and the remainder is
    /// split into lines.
    ///
    /// Invalid UTF-8 is replaced rather than dropped: a multi-byte character
    /// split across two PTY reads would otherwise corrupt the line. (The
    /// prototype accepts a replacement char at a chunk boundary; a production
    /// pane would carry an incremental UTF-8 decoder.)
    pub fn push_bytes(&mut self, bytes: &[u8]) {
        let mut printable = Vec::with_capacity(bytes.len());
        self.filter.feed(bytes, &mut printable);
        let text = String::from_utf8_lossy(&printable);

        for ch in text.chars() {
            // A CR is only a rewind when it is *not* part of a CRLF pair, so
            // the decision has to wait for the next character — which may
            // arrive in the next PTY read, hence the flag on `self`.
            if self.saw_cr {
                self.saw_cr = false;
                if ch == '\n' {
                    self.commit_line();
                    continue;
                }
                // A bare CR: the line restarts at column 0, which is how
                // spinners and progress bars overwrite themselves.
                self.pending.clear();
            }

            match ch {
                '\n' => self.commit_line(),
                '\r' => self.saw_cr = true,
                _ => self.pending.push(ch),
            }
        }
    }

    fn commit_line(&mut self) {
        let line = std::mem::take(&mut self.pending);
        self.lines.push_back(line);
        self.total_lines += 1;
        while self.lines.len() > self.capacity {
            self.lines.pop_front();
        }
    }

    /// Every retained line, oldest first, followed by the in-progress line if
    /// it is non-empty.
    pub fn visible_lines(&self) -> Vec<&str> {
        let mut out: Vec<&str> = self.lines.iter().map(String::as_str).collect();
        if !self.pending.is_empty() {
            out.push(self.pending.as_str());
        }
        out
    }

    /// The last `count` visible lines — what a freshly attached client needs to
    /// paint one screen.
    pub fn tail(&self, count: usize) -> Vec<&str> {
        let all = self.visible_lines();
        let start = all.len().saturating_sub(count);
        all[start..].to_vec()
    }

    /// Number of retained completed lines.
    pub fn len(&self) -> usize {
        self.lines.len()
    }

    pub fn is_empty(&self) -> bool {
        self.lines.is_empty() && self.pending.is_empty()
    }

    /// Total completed lines ever written, including evicted ones.
    pub fn total_lines(&self) -> u64 {
        self.total_lines
    }

    /// How many lines have been dropped off the front.
    pub fn evicted_lines(&self) -> u64 {
        self.total_lines - self.lines.len() as u64
    }

    pub fn clear(&mut self) {
        self.lines.clear();
        self.pending.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_lines_and_holds_a_pending_partial() {
        let mut sb = Scrollback::new(100);
        sb.push_bytes(b"first\nsecond\npart");
        assert_eq!(sb.visible_lines(), ["first", "second", "part"]);
        // Only the two complete lines are retained.
        assert_eq!(sb.len(), 2);
    }

    #[test]
    fn completes_a_partial_line_across_two_writes() {
        let mut sb = Scrollback::new(100);
        sb.push_bytes(b"hel");
        sb.push_bytes(b"lo\n");
        assert_eq!(sb.visible_lines(), ["hello"]);
    }

    #[test]
    fn evicts_oldest_lines_past_capacity() {
        let mut sb = Scrollback::new(3);
        sb.push_bytes(b"1\n2\n3\n4\n5\n");
        assert_eq!(sb.visible_lines(), ["3", "4", "5"]);
        assert_eq!(sb.total_lines(), 5);
        assert_eq!(sb.evicted_lines(), 2);
    }

    #[test]
    fn carriage_return_overwrites_the_current_line() {
        // What a progress spinner actually emits.
        let mut sb = Scrollback::new(10);
        sb.push_bytes(b"working 10%\rworking 90%\n");
        assert_eq!(sb.visible_lines(), ["working 90%"]);
    }

    #[test]
    fn crlf_does_not_produce_a_blank_line() {
        let mut sb = Scrollback::new(10);
        sb.push_bytes(b"a\r\nb\r\n");
        assert_eq!(sb.visible_lines(), ["a", "b"]);
    }

    #[test]
    fn crlf_split_across_two_pty_reads_is_still_one_newline() {
        // The CR ended one read and the LF began the next — the case the
        // buffered-CR flag exists for.
        let mut sb = Scrollback::new(10);
        sb.push_bytes(b"a\r");
        sb.push_bytes(b"\nb\r\n");
        assert_eq!(sb.visible_lines(), ["a", "b"]);
    }

    #[test]
    fn a_bare_cr_split_across_reads_still_rewinds() {
        let mut sb = Scrollback::new(10);
        sb.push_bytes(b"working 10%\r");
        sb.push_bytes(b"working 90%\n");
        assert_eq!(sb.visible_lines(), ["working 90%"]);
    }

    #[test]
    fn strips_escape_sequences_from_stored_lines() {
        let mut sb = Scrollback::new(10);
        sb.push_bytes(b"\x1b[32mgreen\x1b[0m\n");
        assert_eq!(sb.visible_lines(), ["green"]);
    }

    #[test]
    fn tail_returns_the_last_n_lines_and_clamps() {
        let mut sb = Scrollback::new(100);
        sb.push_bytes(b"1\n2\n3\n4\n");
        assert_eq!(sb.tail(2), ["3", "4"]);
        assert_eq!(sb.tail(99), ["1", "2", "3", "4"]);
    }

    #[test]
    fn zero_capacity_is_promoted_to_one() {
        let mut sb = Scrollback::new(0);
        sb.push_bytes(b"a\nb\n");
        assert_eq!(sb.visible_lines(), ["b"]);
    }

    #[test]
    fn preserves_wide_characters() {
        let mut sb = Scrollback::new(10);
        sb.push_bytes("中文测试\n".as_bytes());
        assert_eq!(sb.visible_lines(), ["中文测试"]);
    }
}
