//! The port half of the ports-and-adapters split.
//!
//! Every OS disagreement the bridge cares about is expressed as a trait here
//! and implemented in an adapter crate. Nothing in this module touches the
//! operating system, so the traits can be faked in tests on any host.

use std::path::PathBuf;
use std::sync::mpsc::Receiver;

use anyhow::Result;

/// Terminal geometry, in cells.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PtySize {
    pub rows: u16,
    pub cols: u16,
}

impl PtySize {
    pub fn new(rows: u16, cols: u16) -> Self {
        // A zero-sized PTY makes ConPTY and Unix both misbehave, so clamp at
        // the boundary instead of trusting the caller.
        Self {
            rows: rows.max(1),
            cols: cols.max(1),
        }
    }
}

impl Default for PtySize {
    fn default() -> Self {
        Self { rows: 24, cols: 80 }
    }
}

/// What to run in a new PTY. The shape is identical on Unix and Windows; only
/// the values differ (see [`PlatformProfile::default_shell`]).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SpawnSpec {
    pub program: String,
    pub args: Vec<String>,
    pub cwd: Option<PathBuf>,
    pub env: Vec<(String, String)>,
    pub size: PtySize,
}

impl SpawnSpec {
    pub fn program(program: impl Into<String>) -> Self {
        Self {
            program: program.into(),
            args: Vec::new(),
            cwd: None,
            env: Vec::new(),
            size: PtySize::default(),
        }
    }

    pub fn arg(mut self, arg: impl Into<String>) -> Self {
        self.args.push(arg.into());
        self
    }

    pub fn size(mut self, size: PtySize) -> Self {
        self.size = size;
        self
    }

    pub fn cwd(mut self, cwd: impl Into<PathBuf>) -> Self {
        self.cwd = Some(cwd.into());
        self
    }

    pub fn env(mut self, key: impl Into<String>, value: impl Into<String>) -> Self {
        self.env.push((key.into(), value.into()));
        self
    }
}

/// The write half of a live PTY.
pub trait PtySession: Send {
    fn write(&mut self, data: &[u8]) -> Result<()>;
    fn resize(&mut self, size: PtySize) -> Result<()>;
    /// Terminates the child and everything it spawned. On Windows this is
    /// where a Job Object earns its keep; on Unix, the process group.
    fn kill(&mut self) -> Result<()>;
}

/// A spawned PTY: a write handle plus a stream of output chunks.
///
/// Output arrives on a channel rather than through a callback so the consumer
/// picks its own cadence — the GPUI prototype drains it on a frame timer.
pub struct SpawnedPty {
    pub session: Box<dyn PtySession>,
    pub output: Receiver<Vec<u8>>,
}

/// Creates PTYs. Implemented once, cross-platform, by `herdr-bridge-pty`.
pub trait PtyBackend: Send + Sync {
    fn spawn(&self, spec: &SpawnSpec) -> Result<SpawnedPty>;
}

/// A process in the tree below a shell.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessInfo {
    pub pid: u32,
    pub parent_pid: u32,
    /// Executable name only, without a path — `node`, not `/usr/bin/node`.
    pub name: String,
}

/// Walks process trees so the bridge can tell which agent a pane is running.
///
/// Unix reads `ps`; Windows uses `CreateToolhelp32Snapshot`. Both reduce to the
/// same flat list, and [`descendants_of`] does the tree walk in core where it
/// can be tested.
pub trait ProcessInspector: Send + Sync {
    /// Every process visible to the current user.
    fn snapshot(&self) -> Result<Vec<ProcessInfo>>;
}

/// Collects the transitive children of `root_pid` from a flat process list.
///
/// Lives in core (not in the adapters) because tree walking is exactly the kind
/// of logic that is worth testing and has nothing to do with the OS. Cycles in
/// the parent links — which a PID-reuse race can produce — terminate instead of
/// looping forever.
pub fn descendants_of(processes: &[ProcessInfo], root_pid: u32) -> Vec<ProcessInfo> {
    let mut found = Vec::new();
    let mut frontier = vec![root_pid];
    let mut seen = vec![root_pid];

    while let Some(pid) = frontier.pop() {
        for process in processes.iter().filter(|p| p.parent_pid == pid) {
            if seen.contains(&process.pid) {
                continue;
            }
            seen.push(process.pid);
            frontier.push(process.pid);
            found.push(process.clone());
        }
    }

    found
}

/// The handful of constants and lookups that genuinely differ per OS.
pub trait PlatformProfile: Send + Sync {
    /// Human-readable platform name for the device footer.
    fn name(&self) -> &'static str;

    /// The shell to spawn when no agent command is given.
    fn default_shell(&self) -> SpawnSpec;

    /// A monospace family that is guaranteed to exist on this platform.
    fn monospace_family(&self) -> &'static str;
}

#[cfg(test)]
mod tests {
    use super::*;

    fn process(pid: u32, parent_pid: u32, name: &str) -> ProcessInfo {
        ProcessInfo {
            pid,
            parent_pid,
            name: name.to_string(),
        }
    }

    #[test]
    fn descendants_walks_the_whole_subtree() {
        let processes = vec![
            process(1, 0, "launchd"),
            process(100, 1, "zsh"),
            process(200, 100, "node"), // Claude Code
            process(300, 200, "rg"),   // a grandchild of the agent
            process(400, 1, "unrelated"),
        ];

        let mut names: Vec<String> = descendants_of(&processes, 100)
            .into_iter()
            .map(|p| p.name)
            .collect();
        names.sort();

        assert_eq!(names, ["node", "rg"]);
    }

    #[test]
    fn descendants_of_a_leaf_is_empty() {
        let processes = vec![process(1, 0, "launchd"), process(100, 1, "zsh")];
        assert!(descendants_of(&processes, 100).is_empty());
    }

    #[test]
    fn descendants_terminates_on_a_parent_cycle() {
        // PID reuse can make the parent links circular; this must not hang.
        let processes = vec![process(10, 11, "a"), process(11, 10, "b")];
        let found = descendants_of(&processes, 10);
        // Only 11 is a descendant — 10 is the root, and the cycle back to it
        // must be ignored rather than re-adding it.
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].pid, 11);
    }

    #[test]
    fn pty_size_clamps_zero_dimensions() {
        let size = PtySize::new(0, 0);
        assert_eq!(size, PtySize { rows: 1, cols: 1 });
    }
}
