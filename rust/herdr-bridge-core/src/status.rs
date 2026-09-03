//! Inferring agent status from PTY output.
//!
//! Agents do not report status, so the bridge infers it from what they print
//! plus how long they have been quiet. Time is passed in rather than read from
//! the clock, which is what makes the transitions testable — no sleeps, no
//! flaky timing tests.

use crate::agent::AgentStatus;

/// Substrings that mean the agent is waiting on a human. Matched
/// case-insensitively against the tail of recent output.
const DEFAULT_BLOCKING_MARKERS: &[&str] = &[
    "(y/n)",
    "[y/n]",
    "do you want to proceed",
    "do you want to allow",
    "permission to",
    "press enter to continue",
    "waiting for your input",
];

/// Thresholds for the quiet-based transitions, in milliseconds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ActivityThresholds {
    /// Quiet time after which a working agent is considered finished.
    pub done_after_ms: u64,
    /// Further quiet time after which a finished agent decays to idle, so a
    /// long-abandoned pane stops claiming the top of the sidebar.
    pub idle_after_ms: u64,
}

impl Default for ActivityThresholds {
    fn default() -> Self {
        Self {
            done_after_ms: 1_500,
            idle_after_ms: 60_000,
        }
    }
}

/// Tracks one pane's status.
#[derive(Debug)]
pub struct ActivityDetector {
    status: AgentStatus,
    thresholds: ActivityThresholds,
    last_output_at_ms: u64,
    /// Tail of recent printable output, used for marker matching. Bounded so a
    /// chatty agent cannot grow it without limit.
    recent: String,
    blocking_markers: Vec<String>,
}

/// How much recent output to keep for marker matching. A prompt line is short;
/// this is generous enough to survive being split across reads.
const RECENT_WINDOW: usize = 512;

impl Default for ActivityDetector {
    fn default() -> Self {
        Self::new(ActivityThresholds::default())
    }
}

impl ActivityDetector {
    pub fn new(thresholds: ActivityThresholds) -> Self {
        Self {
            status: AgentStatus::Idle,
            thresholds,
            last_output_at_ms: 0,
            recent: String::new(),
            blocking_markers: DEFAULT_BLOCKING_MARKERS
                .iter()
                .map(|m| m.to_string())
                .collect(),
        }
    }

    /// Replaces the blocking markers, for agents with their own prompt style.
    pub fn with_blocking_markers(mut self, markers: Vec<String>) -> Self {
        self.blocking_markers = markers.into_iter().map(|m| m.to_lowercase()).collect();
        self
    }

    pub fn status(&self) -> AgentStatus {
        self.status
    }

    /// Records printable output (escape sequences already stripped).
    pub fn on_output(&mut self, text: &str, now_ms: u64) {
        self.last_output_at_ms = now_ms;

        self.recent.push_str(&text.to_lowercase());
        if self.recent.len() > RECENT_WINDOW {
            // Trim on a char boundary — output is UTF-8 and may be CJK.
            let cut = self.recent.len() - RECENT_WINDOW;
            let boundary = (cut..self.recent.len())
                .find(|&i| self.recent.is_char_boundary(i))
                .unwrap_or(self.recent.len());
            self.recent.drain(..boundary);
        }

        self.status = if self.is_blocked() {
            AgentStatus::Blocked
        } else {
            AgentStatus::Working
        };
    }

    /// Records that the user sent input, which unblocks the pane and restarts
    /// the working clock.
    pub fn on_user_input(&mut self, now_ms: u64) {
        self.last_output_at_ms = now_ms;
        self.recent.clear();
        self.status = AgentStatus::Working;
    }

    /// Advances quiet-based transitions. Call on a timer.
    pub fn tick(&mut self, now_ms: u64) -> AgentStatus {
        let quiet_ms = now_ms.saturating_sub(self.last_output_at_ms);

        self.status = match self.status {
            // A blocked agent stays blocked until it prints again or the user
            // answers — silence is the whole point of the state.
            AgentStatus::Blocked => AgentStatus::Blocked,
            AgentStatus::Working if quiet_ms >= self.thresholds.done_after_ms => AgentStatus::Done,
            AgentStatus::Done if quiet_ms >= self.thresholds.idle_after_ms => AgentStatus::Idle,
            other => other,
        };

        self.status
    }

    fn is_blocked(&self) -> bool {
        self.blocking_markers
            .iter()
            .any(|marker| self.recent.contains(marker.as_str()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn detector() -> ActivityDetector {
        ActivityDetector::new(ActivityThresholds {
            done_after_ms: 1_000,
            idle_after_ms: 10_000,
        })
    }

    #[test]
    fn starts_idle() {
        assert_eq!(detector().status(), AgentStatus::Idle);
    }

    #[test]
    fn output_marks_working() {
        let mut d = detector();
        d.on_output("compiling...", 100);
        assert_eq!(d.status(), AgentStatus::Working);
    }

    #[test]
    fn working_becomes_done_after_the_quiet_threshold() {
        let mut d = detector();
        d.on_output("built", 0);
        assert_eq!(d.tick(999), AgentStatus::Working);
        assert_eq!(d.tick(1_000), AgentStatus::Done);
    }

    #[test]
    fn done_decays_to_idle_much_later() {
        let mut d = detector();
        d.on_output("built", 0);
        assert_eq!(d.tick(1_000), AgentStatus::Done);
        assert_eq!(d.tick(9_999), AgentStatus::Done);
        assert_eq!(d.tick(10_000), AgentStatus::Idle);
    }

    #[test]
    fn a_permission_prompt_blocks() {
        let mut d = detector();
        d.on_output("Do you want to proceed? (y/n)", 0);
        assert_eq!(d.status(), AgentStatus::Blocked);
    }

    #[test]
    fn blocked_survives_silence() {
        // This is the case that matters: a blocked agent must not decay into
        // Done and lose its place at the top of the sidebar.
        let mut d = detector();
        d.on_output("Do you want to allow this edit?", 0);
        assert_eq!(d.tick(60_000), AgentStatus::Blocked);
    }

    #[test]
    fn user_input_clears_blocked_and_resumes_working() {
        let mut d = detector();
        d.on_output("(y/n)", 0);
        assert_eq!(d.status(), AgentStatus::Blocked);
        d.on_user_input(500);
        assert_eq!(d.status(), AgentStatus::Working);
        // The stale prompt text must not re-block on the next tick.
        assert_eq!(d.tick(600), AgentStatus::Working);
    }

    #[test]
    fn marker_matching_is_case_insensitive() {
        let mut d = detector();
        d.on_output("DO YOU WANT TO PROCEED", 0);
        assert_eq!(d.status(), AgentStatus::Blocked);
    }

    #[test]
    fn marker_split_across_two_writes_still_matches() {
        let mut d = detector();
        d.on_output("Do you want ", 0);
        d.on_output("to proceed?", 1);
        assert_eq!(d.status(), AgentStatus::Blocked);
    }

    #[test]
    fn recent_window_trimming_handles_multibyte_output() {
        // Must not panic on a non-char-boundary trim.
        let mut d = detector();
        for i in 0..50 {
            d.on_output("中文输出测试中文输出测试中文输出测试", i);
        }
        assert_eq!(d.status(), AgentStatus::Working);
    }

    #[test]
    fn custom_markers_replace_the_defaults() {
        let mut d = detector().with_blocking_markers(vec!["awaiting approval".to_string()]);
        d.on_output("(y/n)", 0);
        assert_eq!(d.status(), AgentStatus::Working);
        d.on_output("awaiting approval", 1);
        assert_eq!(d.status(), AgentStatus::Blocked);
    }
}
