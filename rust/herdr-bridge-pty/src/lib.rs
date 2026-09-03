//! The real [`PtyBackend`], over `portable-pty`.
//!
//! This crate has **no** `#[cfg(unix)]` / `#[cfg(windows)]` either, and that is
//! the whole point: `portable-pty` (WezTerm's crate, also used by Zed) presents
//! one API over Unix `openpty`/`forkpty` and Windows `CreatePseudoConsole`
//! (ConPTY). Spawning `zsh` on a Mac and `pwsh.exe` on Windows is the same code
//! path, so the PTY plumbing is debuggable on macOS.
//!
//! What still differs per OS — default shell, process inspection, Job Objects —
//! lives in `herdr-bridge-sys-unix` / `herdr-bridge-sys-windows`.

use std::io::{Read, Write};
use std::sync::mpsc::{channel, Sender};
use std::thread;

use anyhow::{Context, Result};
use herdr_bridge_core::platform::{PtyBackend, PtySession, PtySize, SpawnSpec, SpawnedPty};
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize as PortableSize};

/// Read buffer size for the PTY reader thread. Agent TUIs repaint in bursts, so
/// this is sized to swallow a full repaint in one read.
const READ_BUFFER: usize = 8 * 1024;

fn to_portable(size: PtySize) -> PortableSize {
    PortableSize {
        rows: size.rows,
        cols: size.cols,
        pixel_width: 0,
        pixel_height: 0,
    }
}

/// A live PTY plus the child running inside it.
struct PortablePtySession {
    /// Kept alive for the lifetime of the session: dropping the master closes
    /// the PTY and kills the child on both platforms.
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn Child + Send + Sync>,
}

impl PtySession for PortablePtySession {
    fn write(&mut self, data: &[u8]) -> Result<()> {
        self.writer.write_all(data).context("write to pty")?;
        // Agent TUIs are interactive; never let input sit in a buffer.
        self.writer.flush().context("flush pty")?;
        Ok(())
    }

    fn resize(&mut self, size: PtySize) -> Result<()> {
        self.master
            .resize(to_portable(size))
            .context("resize pty")?;
        Ok(())
    }

    fn kill(&mut self) -> Result<()> {
        self.child.kill().context("kill pty child")?;
        // Reap so the child does not linger as a zombie on Unix.
        let _ = self.child.wait();
        Ok(())
    }
}

/// Creates PTYs using whatever the host provides.
#[derive(Debug, Default, Clone, Copy)]
pub struct PortablePtyBackend;

impl PortablePtyBackend {
    pub fn new() -> Self {
        Self
    }
}

impl PtyBackend for PortablePtyBackend {
    fn spawn(&self, spec: &SpawnSpec) -> Result<SpawnedPty> {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(to_portable(spec.size))
            .context("openpty")?;

        let mut command = CommandBuilder::new(&spec.program);
        command.args(&spec.args);
        if let Some(cwd) = &spec.cwd {
            command.cwd(cwd);
        }
        for (key, value) in &spec.env {
            command.env(key, value);
        }

        let child = pair
            .slave
            .spawn_command(command)
            .with_context(|| format!("spawn {}", spec.program))?;

        // Drop the slave handle in the parent: on Unix a retained slave fd
        // keeps the PTY open so the reader never sees EOF when the child exits.
        drop(pair.slave);

        let mut reader = pair.master.try_clone_reader().context("clone pty reader")?;
        let writer = pair.master.take_writer().context("take pty writer")?;

        let (tx, rx) = channel();
        // A dedicated thread rather than async: portable-pty's reader is
        // blocking, and on Windows ConPTY reads cannot be polled.
        thread::Builder::new()
            .name(format!("pty-read-{}", spec.program))
            .spawn(move || pump_reader(&mut reader, tx))
            .context("spawn pty reader thread")?;

        Ok(SpawnedPty {
            session: Box::new(PortablePtySession {
                master: pair.master,
                writer,
                child,
            }),
            output: rx,
        })
    }
}

/// Forwards PTY output until EOF or the consumer goes away.
fn pump_reader(reader: &mut (dyn Read + Send), tx: Sender<Vec<u8>>) {
    let mut buffer = vec![0u8; READ_BUFFER];
    loop {
        match reader.read(&mut buffer) {
            // EOF: the child exited. Dropping `tx` tells the pane.
            Ok(0) => break,
            Ok(count) => {
                if tx.send(buffer[..count].to_vec()).is_err() {
                    // The pane was closed; stop reading.
                    break;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Waits for `predicate` to hold, pumping the channel. Bounded so a
    /// regression fails the test instead of hanging CI.
    fn collect_until(spawned: &mut SpawnedPty, predicate: impl Fn(&str) -> bool) -> String {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
        let mut output = Vec::new();
        while std::time::Instant::now() < deadline {
            if let Ok(chunk) = spawned
                .output
                .recv_timeout(std::time::Duration::from_millis(100))
            {
                output.extend_from_slice(&chunk);
                let text = String::from_utf8_lossy(&output).into_owned();
                if predicate(&text) {
                    return text;
                }
            }
        }
        String::from_utf8_lossy(&output).into_owned()
    }

    // These tests spawn a real process through a real PTY. They pass on macOS
    // and Linux as written; on Windows the equivalent command differs, so the
    // command is chosen per platform at *runtime* by CI rather than compiled in.
    #[test]
    fn spawns_a_process_and_streams_its_output() {
        let echo = if cfg!(windows) { "cmd" } else { "echo" };
        let spec = if cfg!(windows) {
            SpawnSpec::program(echo).arg("/C").arg("echo herdr-pty-ok")
        } else {
            SpawnSpec::program(echo).arg("herdr-pty-ok")
        };

        let backend = PortablePtyBackend::new();
        let mut spawned = backend.spawn(&spec).expect("spawn");
        let output = collect_until(&mut spawned, |text| text.contains("herdr-pty-ok"));
        assert!(
            output.contains("herdr-pty-ok"),
            "expected marker in PTY output, got: {output:?}"
        );
    }

    #[test]
    fn writing_input_reaches_the_child() {
        // `cat` echoes stdin back through the PTY.
        if cfg!(windows) {
            return; // no `cat`; covered on Windows by the shell test in CI
        }

        let backend = PortablePtyBackend::new();
        let mut spawned = backend
            .spawn(&SpawnSpec::program("cat"))
            .expect("spawn cat");

        spawned
            .session
            .write(b"round-trip\n")
            .expect("write to pty");

        let output = collect_until(&mut spawned, |text| text.contains("round-trip"));
        assert!(
            output.contains("round-trip"),
            "expected echoed input, got: {output:?}"
        );
        spawned.session.kill().expect("kill");
    }

    #[test]
    fn resize_succeeds_on_a_live_pty() {
        let backend = PortablePtyBackend::new();
        let program = if cfg!(windows) { "cmd" } else { "cat" };
        let mut spawned = backend
            .spawn(&SpawnSpec::program(program).size(PtySize::new(24, 80)))
            .expect("spawn");

        spawned
            .session
            .resize(PtySize::new(50, 200))
            .expect("resize live pty");
        spawned.session.kill().expect("kill");
    }

    #[test]
    fn spawning_a_missing_program_is_an_error_not_a_panic() {
        let backend = PortablePtyBackend::new();
        let result = backend.spawn(&SpawnSpec::program(
            "herdr-definitely-not-a-real-binary-9f2a",
        ));
        assert!(result.is_err());
    }
}
