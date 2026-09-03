//! Pane multiplexing: the registry that owns every live PTY.
//!
//! This is the piece that the phone and the desktop both talk to, and the piece
//! most likely to have bugs — so it is written against the [`PtyBackend`] trait
//! and exercised in tests with a fake backend, no real processes involved.

use std::collections::BTreeMap;
use std::fmt;
use std::sync::mpsc::{Receiver, TryRecvError};
use std::sync::Arc;

use anyhow::{anyhow, Result};

use crate::agent::{Agent, AgentKind, AgentStatus};
use crate::platform::{PtyBackend, PtySession, PtySize, SpawnSpec};
use crate::scrollback::Scrollback;
use crate::status::ActivityDetector;
use crate::vt::AnsiFilter;

/// Opaque pane identifier.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct PaneId(String);

impl PaneId {
    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl fmt::Display for PaneId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// How many lines of history each pane retains.
const DEFAULT_SCROLLBACK: usize = 10_000;

/// One attached terminal: a PTY, its history, and its inferred status.
pub struct Pane {
    pub id: PaneId,
    pub title: String,
    pub space: String,
    pub kind: AgentKind,
    scrollback: Scrollback,
    detector: ActivityDetector,
    session: Box<dyn PtySession>,
    output: Receiver<Vec<u8>>,
    size: PtySize,
    /// Separate from the scrollback's filter: status matching needs printable
    /// text before it is split into lines.
    status_filter: AnsiFilter,
    exited: bool,
}

impl Pane {
    /// Drains everything the PTY has produced since the last call.
    ///
    /// Returns whether anything changed, so a UI can skip redrawing. Never
    /// blocks: a pane with no output returns immediately.
    pub fn pump(&mut self, now_ms: u64) -> bool {
        let mut changed = false;

        loop {
            match self.output.try_recv() {
                Ok(chunk) => {
                    self.scrollback.push_bytes(&chunk);

                    let mut printable = Vec::with_capacity(chunk.len());
                    self.status_filter.feed(&chunk, &mut printable);
                    self.detector
                        .on_output(&String::from_utf8_lossy(&printable), now_ms);

                    changed = true;
                }
                Err(TryRecvError::Empty) => break,
                Err(TryRecvError::Disconnected) => {
                    // The reader thread ended, which means the child is gone.
                    if !self.exited {
                        self.exited = true;
                        changed = true;
                    }
                    break;
                }
            }
        }

        let before = self.detector.status();
        if self.detector.tick(now_ms) != before {
            changed = true;
        }

        changed
    }

    /// Sends user input to the child.
    pub fn write_input(&mut self, data: &[u8], now_ms: u64) -> Result<()> {
        self.session.write(data)?;
        self.detector.on_user_input(now_ms);
        Ok(())
    }

    pub fn resize(&mut self, size: PtySize) -> Result<()> {
        if size == self.size {
            return Ok(());
        }
        self.session.resize(size)?;
        self.size = size;
        Ok(())
    }

    pub fn size(&self) -> PtySize {
        self.size
    }

    pub fn status(&self) -> AgentStatus {
        self.detector.status()
    }

    /// Whether the child process has gone away.
    pub fn has_exited(&self) -> bool {
        self.exited
    }

    /// The last `count` lines — a screen replay for a client that just
    /// attached.
    pub fn tail(&self, count: usize) -> Vec<&str> {
        self.scrollback.tail(count)
    }

    pub fn scrollback(&self) -> &Scrollback {
        &self.scrollback
    }

    /// The sidebar's view of this pane.
    pub fn as_agent(&self) -> Agent {
        Agent {
            pane_id: self.id.0.clone(),
            name: self.title.clone(),
            space: self.space.clone(),
            kind: self.kind.clone(),
            status: self.status(),
        }
    }
}

/// Owns every pane and the backend that creates them.
pub struct PaneRegistry {
    backend: Arc<dyn PtyBackend>,
    panes: BTreeMap<PaneId, Pane>,
    next_id: u64,
    scrollback_capacity: usize,
}

impl PaneRegistry {
    pub fn new(backend: Arc<dyn PtyBackend>) -> Self {
        Self {
            backend,
            panes: BTreeMap::new(),
            next_id: 1,
            scrollback_capacity: DEFAULT_SCROLLBACK,
        }
    }

    pub fn with_scrollback_capacity(mut self, capacity: usize) -> Self {
        self.scrollback_capacity = capacity;
        self
    }

    /// Spawns a PTY and registers it as a pane.
    pub fn create(
        &mut self,
        space: impl Into<String>,
        title: impl Into<String>,
        spec: &SpawnSpec,
    ) -> Result<PaneId> {
        let spawned = self.backend.spawn(spec)?;

        // Ids are allocated here rather than by the backend so a failed spawn
        // does not burn an id.
        let id = PaneId::new(format!("pane-{}", self.next_id));
        self.next_id += 1;

        let pane = Pane {
            id: id.clone(),
            title: title.into(),
            space: space.into(),
            kind: AgentKind::from_name(&spec.program),
            scrollback: Scrollback::new(self.scrollback_capacity),
            detector: ActivityDetector::default(),
            session: spawned.session,
            output: spawned.output,
            size: spec.size,
            status_filter: AnsiFilter::new(),
            exited: false,
        };

        self.panes.insert(id.clone(), pane);
        Ok(id)
    }

    pub fn get(&self, id: &PaneId) -> Option<&Pane> {
        self.panes.get(id)
    }

    pub fn get_mut(&mut self, id: &PaneId) -> Option<&mut Pane> {
        self.panes.get_mut(id)
    }

    /// Pumps every pane. Returns whether any of them changed.
    pub fn pump_all(&mut self, now_ms: u64) -> bool {
        let mut changed = false;
        for pane in self.panes.values_mut() {
            changed |= pane.pump(now_ms);
        }
        changed
    }

    /// Every pane as a sidebar entry, already sorted by status bucket.
    pub fn agents(&self) -> Vec<Agent> {
        let mut agents: Vec<Agent> = self.panes.values().map(Pane::as_agent).collect();
        crate::agent::sort_agents(&mut agents);
        agents
    }

    /// Distinct spaces, sorted, for the sidebar's Spaces section.
    pub fn spaces(&self) -> Vec<String> {
        let mut spaces: Vec<String> = self.panes.values().map(|p| p.space.clone()).collect();
        spaces.sort();
        spaces.dedup();
        spaces
    }

    pub fn ids(&self) -> Vec<PaneId> {
        self.panes.keys().cloned().collect()
    }

    pub fn len(&self) -> usize {
        self.panes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.panes.is_empty()
    }

    /// Kills the child and forgets the pane.
    pub fn close(&mut self, id: &PaneId) -> Result<()> {
        let mut pane = self
            .panes
            .remove(id)
            .ok_or_else(|| anyhow!("no such pane: {id}"))?;
        pane.session.kill()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc::{channel, Sender};
    use std::sync::Mutex;

    use crate::platform::SpawnedPty;

    use super::*;

    /// Records what was written and lets a test push output back.
    struct FakeSession {
        written: Arc<Mutex<Vec<u8>>>,
        resized_to: Arc<Mutex<Option<PtySize>>>,
        killed: Arc<Mutex<bool>>,
    }

    impl PtySession for FakeSession {
        fn write(&mut self, data: &[u8]) -> Result<()> {
            self.written.lock().expect("lock").extend_from_slice(data);
            Ok(())
        }

        fn resize(&mut self, size: PtySize) -> Result<()> {
            *self.resized_to.lock().expect("lock") = Some(size);
            Ok(())
        }

        fn kill(&mut self) -> Result<()> {
            *self.killed.lock().expect("lock") = true;
            Ok(())
        }
    }

    struct FakeBackend {
        written: Arc<Mutex<Vec<u8>>>,
        resized_to: Arc<Mutex<Option<PtySize>>>,
        killed: Arc<Mutex<bool>>,
        senders: Mutex<Vec<Sender<Vec<u8>>>>,
        spawned_specs: Mutex<Vec<SpawnSpec>>,
    }

    impl FakeBackend {
        fn new() -> Arc<Self> {
            Arc::new(Self {
                written: Arc::new(Mutex::new(Vec::new())),
                resized_to: Arc::new(Mutex::new(None)),
                killed: Arc::new(Mutex::new(false)),
                senders: Mutex::new(Vec::new()),
                spawned_specs: Mutex::new(Vec::new()),
            })
        }

        /// Pushes output as if the child had printed it.
        fn emit(&self, index: usize, bytes: &[u8]) {
            self.senders.lock().expect("lock")[index]
                .send(bytes.to_vec())
                .expect("send");
        }

        /// Drops the sender, simulating the child exiting.
        fn close_output(&self, index: usize) {
            self.senders.lock().expect("lock").remove(index);
        }
    }

    impl PtyBackend for FakeBackend {
        fn spawn(&self, spec: &SpawnSpec) -> Result<SpawnedPty> {
            let (tx, rx) = channel();
            self.senders.lock().expect("lock").push(tx);
            self.spawned_specs.lock().expect("lock").push(spec.clone());
            Ok(SpawnedPty {
                session: Box::new(FakeSession {
                    written: Arc::clone(&self.written),
                    resized_to: Arc::clone(&self.resized_to),
                    killed: Arc::clone(&self.killed),
                }),
                output: rx,
            })
        }
    }

    #[test]
    fn create_spawns_through_the_backend_and_returns_an_id() {
        let backend = FakeBackend::new();
        let mut registry = PaneRegistry::new(Arc::clone(&backend) as Arc<dyn PtyBackend>);

        let id = registry
            .create("herdrm", "Claude", &SpawnSpec::program("claude"))
            .expect("create");

        assert_eq!(id.as_str(), "pane-1");
        assert_eq!(registry.len(), 1);
        assert_eq!(
            backend.spawned_specs.lock().expect("lock")[0].program,
            "claude"
        );
    }

    #[test]
    fn pane_kind_is_derived_from_the_spawned_program() {
        let backend = FakeBackend::new();
        let mut registry = PaneRegistry::new(backend as Arc<dyn PtyBackend>);
        let id = registry
            .create("herdrm", "Agent", &SpawnSpec::program("claude"))
            .expect("create");
        assert_eq!(registry.get(&id).expect("pane").kind, AgentKind::ClaudeCode);
    }

    #[test]
    fn pump_moves_output_into_scrollback_and_marks_working() {
        let backend = FakeBackend::new();
        let mut registry = PaneRegistry::new(Arc::clone(&backend) as Arc<dyn PtyBackend>);
        let id = registry
            .create("herdrm", "Claude", &SpawnSpec::program("claude"))
            .expect("create");

        backend.emit(0, b"\x1b[32mbuilding\x1b[0m\n");
        assert!(registry.pump_all(100));

        let pane = registry.get(&id).expect("pane");
        assert_eq!(pane.tail(10), ["building"]);
        assert_eq!(pane.status(), AgentStatus::Working);
    }

    #[test]
    fn pump_with_no_output_reports_no_change() {
        let backend = FakeBackend::new();
        let mut registry = PaneRegistry::new(backend as Arc<dyn PtyBackend>);
        registry
            .create("herdrm", "Claude", &SpawnSpec::program("claude"))
            .expect("create");
        assert!(!registry.pump_all(0));
    }

    #[test]
    fn a_quiet_pane_transitions_to_done_on_a_later_pump() {
        let backend = FakeBackend::new();
        let mut registry = PaneRegistry::new(Arc::clone(&backend) as Arc<dyn PtyBackend>);
        let id = registry
            .create("herdrm", "Claude", &SpawnSpec::program("claude"))
            .expect("create");

        backend.emit(0, b"done building\n");
        registry.pump_all(0);
        assert_eq!(
            registry.get(&id).expect("pane").status(),
            AgentStatus::Working
        );

        // Nothing new arrives; the status change alone counts as a change.
        assert!(registry.pump_all(5_000));
        assert_eq!(registry.get(&id).expect("pane").status(), AgentStatus::Done);
    }

    #[test]
    fn write_input_reaches_the_session_and_resumes_working() {
        let backend = FakeBackend::new();
        let mut registry = PaneRegistry::new(Arc::clone(&backend) as Arc<dyn PtyBackend>);
        let id = registry
            .create("herdrm", "Claude", &SpawnSpec::program("claude"))
            .expect("create");

        backend.emit(0, b"Do you want to proceed? (y/n)");
        registry.pump_all(0);
        assert_eq!(
            registry.get(&id).expect("pane").status(),
            AgentStatus::Blocked
        );

        registry
            .get_mut(&id)
            .expect("pane")
            .write_input(b"y\r", 10)
            .expect("write");

        assert_eq!(*backend.written.lock().expect("lock"), b"y\r");
        assert_eq!(
            registry.get(&id).expect("pane").status(),
            AgentStatus::Working
        );
    }

    #[test]
    fn resize_is_forwarded_once_and_deduplicated() {
        let backend = FakeBackend::new();
        let mut registry = PaneRegistry::new(Arc::clone(&backend) as Arc<dyn PtyBackend>);
        let id = registry
            .create("herdrm", "Claude", &SpawnSpec::program("claude"))
            .expect("create");

        let pane = registry.get_mut(&id).expect("pane");
        pane.resize(PtySize::new(40, 120)).expect("resize");
        assert_eq!(
            *backend.resized_to.lock().expect("lock"),
            Some(PtySize::new(40, 120))
        );

        // Same size again must not reach the OS.
        *backend.resized_to.lock().expect("lock") = None;
        pane.resize(PtySize::new(40, 120)).expect("resize");
        assert_eq!(*backend.resized_to.lock().expect("lock"), None);
    }

    #[test]
    fn a_dropped_output_channel_marks_the_pane_exited_once() {
        let backend = FakeBackend::new();
        let mut registry = PaneRegistry::new(Arc::clone(&backend) as Arc<dyn PtyBackend>);
        let id = registry
            .create("herdrm", "Shell", &SpawnSpec::program("zsh"))
            .expect("create");

        backend.close_output(0);
        assert!(registry.pump_all(0));
        assert!(registry.get(&id).expect("pane").has_exited());

        // The exit is reported once, not on every subsequent pump.
        assert!(!registry.pump_all(1));
    }

    #[test]
    fn agents_are_sorted_by_status_bucket() {
        let backend = FakeBackend::new();
        let mut registry = PaneRegistry::new(Arc::clone(&backend) as Arc<dyn PtyBackend>);
        registry
            .create("herdrm", "working-agent", &SpawnSpec::program("claude"))
            .expect("create");
        registry
            .create("herdrm", "blocked-agent", &SpawnSpec::program("codex"))
            .expect("create");

        backend.emit(0, b"compiling\n");
        backend.emit(1, b"Do you want to proceed? (y/n)");
        registry.pump_all(0);

        let agents = registry.agents();
        assert_eq!(agents[0].name, "blocked-agent");
        assert_eq!(agents[0].status, AgentStatus::Blocked);
        assert_eq!(agents[1].name, "working-agent");
    }

    #[test]
    fn spaces_are_deduplicated_and_sorted() {
        let backend = FakeBackend::new();
        let mut registry = PaneRegistry::new(backend as Arc<dyn PtyBackend>);
        registry
            .create("zeta", "a", &SpawnSpec::program("zsh"))
            .expect("create");
        registry
            .create("alpha", "b", &SpawnSpec::program("zsh"))
            .expect("create");
        registry
            .create("alpha", "c", &SpawnSpec::program("zsh"))
            .expect("create");

        assert_eq!(registry.spaces(), ["alpha", "zeta"]);
    }

    #[test]
    fn close_kills_the_session_and_removes_the_pane() {
        let backend = FakeBackend::new();
        let mut registry = PaneRegistry::new(Arc::clone(&backend) as Arc<dyn PtyBackend>);
        let id = registry
            .create("herdrm", "Shell", &SpawnSpec::program("zsh"))
            .expect("create");

        registry.close(&id).expect("close");
        assert!(registry.is_empty());
        assert!(*backend.killed.lock().expect("lock"));
    }

    #[test]
    fn closing_an_unknown_pane_is_an_error() {
        let backend = FakeBackend::new();
        let mut registry = PaneRegistry::new(backend as Arc<dyn PtyBackend>);
        assert!(registry.close(&PaneId::new("nope")).is_err());
    }
}
