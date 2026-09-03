//! Agent identity and status, mirroring herdr's domain model.

use serde::{Deserialize, Serialize};

/// Status buckets sort Blocked > Done > Working > Idle, matching herdr and
/// Heeler so the desktop and mobile clients agree on ordering.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentStatus {
    /// Waiting on the human: a permission prompt or a question.
    Blocked,
    /// Finished its turn and has nothing queued.
    Done,
    /// Actively producing output.
    Working,
    /// Attached but quiet.
    Idle,
}

impl AgentStatus {
    /// Lower rank sorts first. Kept explicit rather than deriving from the
    /// variant order so reordering the enum cannot silently reorder the UI.
    pub fn sort_rank(self) -> u8 {
        match self {
            AgentStatus::Blocked => 0,
            AgentStatus::Done => 1,
            AgentStatus::Working => 2,
            AgentStatus::Idle => 3,
        }
    }

    /// Whether the status should pull the user's eye in a sidebar.
    pub fn needs_attention(self) -> bool {
        matches!(self, AgentStatus::Blocked | AgentStatus::Done)
    }

    pub fn label(self) -> &'static str {
        match self {
            AgentStatus::Blocked => "Blocked",
            AgentStatus::Done => "Done",
            AgentStatus::Working => "Working",
            AgentStatus::Idle => "Idle",
        }
    }
}

/// Which coding agent is running in a pane. `Other` keeps unknown agents
/// representable instead of forcing a lossy fallback.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AgentKind {
    ClaudeCode,
    Codex,
    Cursor,
    Aider,
    Gemini,
    Shell,
    Other(String),
}

impl AgentKind {
    /// Maps an executable or agent name as herdr reports it.
    pub fn from_name(name: &str) -> Self {
        match name.trim().to_ascii_lowercase().as_str() {
            "claude" | "claude-code" | "claudecode" => AgentKind::ClaudeCode,
            "codex" => AgentKind::Codex,
            // herdr aliases `cursor` to the cursor-agent binary.
            "cursor" | "cursor-agent" => AgentKind::Cursor,
            "aider" => AgentKind::Aider,
            "gemini" => AgentKind::Gemini,
            "shell" | "zsh" | "bash" | "fish" | "pwsh" | "powershell" | "cmd" => AgentKind::Shell,
            other => AgentKind::Other(other.to_string()),
        }
    }

    pub fn display_name(&self) -> &str {
        match self {
            AgentKind::ClaudeCode => "Claude Code",
            AgentKind::Codex => "Codex",
            AgentKind::Cursor => "Cursor",
            AgentKind::Aider => "Aider",
            AgentKind::Gemini => "Gemini",
            AgentKind::Shell => "Shell",
            AgentKind::Other(name) => name,
        }
    }
}

/// An agent as listed in the sidebar.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Agent {
    pub pane_id: String,
    pub name: String,
    /// The herdr workspace ("Space") this agent belongs to.
    pub space: String,
    pub kind: AgentKind,
    pub status: AgentStatus,
}

/// Sorts by status bucket, then by name, so the list is stable across polls
/// even when two agents share a status.
pub fn sort_agents(agents: &mut [Agent]) {
    agents.sort_by(|a, b| {
        a.status
            .sort_rank()
            .cmp(&b.status.sort_rank())
            .then_with(|| a.name.cmp(&b.name))
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn agent(name: &str, status: AgentStatus) -> Agent {
        Agent {
            pane_id: format!("pane-{name}"),
            name: name.to_string(),
            space: "herdrm".to_string(),
            kind: AgentKind::ClaudeCode,
            status,
        }
    }

    #[test]
    fn status_buckets_sort_blocked_done_working_idle() {
        let mut ranks = [
            AgentStatus::Idle,
            AgentStatus::Working,
            AgentStatus::Done,
            AgentStatus::Blocked,
        ];
        ranks.sort_by_key(|s| s.sort_rank());
        assert_eq!(
            ranks,
            [
                AgentStatus::Blocked,
                AgentStatus::Done,
                AgentStatus::Working,
                AgentStatus::Idle
            ]
        );
    }

    #[test]
    fn sort_agents_breaks_status_ties_by_name() {
        let mut agents = vec![
            agent("zeta", AgentStatus::Working),
            agent("idle-one", AgentStatus::Idle),
            agent("alpha", AgentStatus::Working),
            agent("blocked", AgentStatus::Blocked),
        ];
        sort_agents(&mut agents);
        let names: Vec<&str> = agents.iter().map(|a| a.name.as_str()).collect();
        assert_eq!(names, ["blocked", "alpha", "zeta", "idle-one"]);
    }

    #[test]
    fn only_blocked_and_done_need_attention() {
        assert!(AgentStatus::Blocked.needs_attention());
        assert!(AgentStatus::Done.needs_attention());
        assert!(!AgentStatus::Working.needs_attention());
        assert!(!AgentStatus::Idle.needs_attention());
    }

    #[test]
    fn agent_kind_maps_cursor_alias_and_keeps_unknowns() {
        assert_eq!(AgentKind::from_name("cursor-agent"), AgentKind::Cursor);
        assert_eq!(AgentKind::from_name("Claude-Code"), AgentKind::ClaudeCode);
        // A Windows default shell must not degrade into `Other`.
        assert_eq!(AgentKind::from_name("pwsh"), AgentKind::Shell);
        assert_eq!(
            AgentKind::from_name("my-agent"),
            AgentKind::Other("my-agent".to_string())
        );
    }

    #[test]
    fn status_round_trips_as_snake_case_json() {
        let json = serde_json::to_string(&AgentStatus::Blocked).expect("serialize");
        assert_eq!(json, "\"blocked\"");
        let back: AgentStatus = serde_json::from_str(&json).expect("deserialize");
        assert_eq!(back, AgentStatus::Blocked);
    }
}
