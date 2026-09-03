//! End-to-end smoke test of the stack the desktop client runs on:
//! `PaneRegistry` → `PortablePtyBackend` → a real PTY → a real child process.
//!
//! This is the test that would fail if the Windows port broke the parts that
//! are *not* platform-specific, and it runs unchanged on macOS, Linux and
//! Windows — the point of §3.6 of the Windows plan. Only the command differs,
//! and it is chosen at runtime.

use std::sync::Arc;
use std::time::{Duration, Instant};

use herdr_bridge_core::platform::{PtyBackend, PtySize};
use herdr_bridge_core::{AgentStatus, PaneRegistry, SpawnSpec};
use herdr_bridge_pty::PortablePtyBackend;

/// Pumps the registry until `predicate` passes or the deadline expires.
fn pump_until(
    registry: &mut PaneRegistry,
    id: &herdr_bridge_core::PaneId,
    timeout: Duration,
    predicate: impl Fn(&herdr_bridge_core::Pane) -> bool,
) -> bool {
    let start = Instant::now();
    while start.elapsed() < timeout {
        let elapsed_ms = start.elapsed().as_millis() as u64;
        registry.pump_all(elapsed_ms);
        if let Some(pane) = registry.get(id) {
            if predicate(pane) {
                return true;
            }
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    false
}

/// A command that prints `marker` and exits, on whichever host we are on.
fn echo_spec(marker: &str) -> SpawnSpec {
    if cfg!(windows) {
        SpawnSpec::program("cmd")
            .arg("/C")
            .arg(format!("echo {marker}"))
    } else {
        SpawnSpec::program("/bin/sh")
            .arg("-c")
            .arg(format!("echo {marker}"))
    }
}

#[test]
fn a_real_child_process_reaches_the_scrollback() {
    let backend: Arc<dyn PtyBackend> = Arc::new(PortablePtyBackend::new());
    let mut registry = PaneRegistry::new(backend);

    let marker = "herdr-smoke-marker";
    let id = registry
        .create(
            "local",
            "smoke",
            &echo_spec(marker).size(PtySize::new(24, 80)),
        )
        .expect("create pane");

    let found = pump_until(&mut registry, &id, Duration::from_secs(15), |pane| {
        pane.scrollback()
            .visible_lines()
            .iter()
            .any(|line| line.contains(marker))
    });

    let pane = registry.get(&id).expect("pane");
    assert!(
        found,
        "marker never arrived; scrollback was {:?}",
        pane.scrollback().visible_lines()
    );

    // Output moved the pane out of Idle, which is what drives the sidebar dot.
    assert_ne!(pane.status(), AgentStatus::Idle);
}

#[test]
fn the_pane_notices_when_the_child_exits() {
    let backend: Arc<dyn PtyBackend> = Arc::new(PortablePtyBackend::new());
    let mut registry = PaneRegistry::new(backend);

    let id = registry
        .create("local", "exits", &echo_spec("bye"))
        .expect("create pane");

    let exited = pump_until(&mut registry, &id, Duration::from_secs(15), |pane| {
        pane.has_exited()
    });

    assert!(exited, "pane never observed the child exiting");
}

#[test]
fn input_written_to_a_shell_comes_back_as_output() {
    // A round trip through the PTY: write a command, read its result. This is
    // the path the desktop client's keyboard handler drives.
    if cfg!(windows) {
        // cmd.exe echoes and prompts differently; covered on Windows in CI by
        // the shell-specific test rather than shoehorned in here.
        return;
    }

    let backend: Arc<dyn PtyBackend> = Arc::new(PortablePtyBackend::new());
    let mut registry = PaneRegistry::new(backend);

    let id = registry
        .create(
            "local",
            "sh",
            &SpawnSpec::program("/bin/sh").size(PtySize::new(24, 80)),
        )
        .expect("create pane");

    registry
        .get_mut(&id)
        .expect("pane")
        .write_input(b"echo round-trip-ok\n", 0)
        .expect("write input");

    let found = pump_until(&mut registry, &id, Duration::from_secs(15), |pane| {
        pane.scrollback()
            .visible_lines()
            .iter()
            .any(|line| line.contains("round-trip-ok"))
    });

    assert!(
        found,
        "no echo of the written command; scrollback was {:?}",
        registry
            .get(&id)
            .expect("pane")
            .scrollback()
            .visible_lines()
    );

    registry.close(&id).expect("close pane");
}
