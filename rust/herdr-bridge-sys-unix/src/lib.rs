//! Unix adapter: the parts of the bridge that Windows does differently.
//!
//! Compiles to an empty crate elsewhere, so `cargo build --workspace` stays
//! green on any host.
#![cfg(unix)]

use std::process::Command;

use anyhow::{Context, Result};
use herdr_bridge_core::platform::{PlatformProfile, ProcessInfo, ProcessInspector, SpawnSpec};

/// Shells to fall back through when `$SHELL` is unset or unusable.
const SHELL_FALLBACKS: &[&str] = &["/bin/zsh", "/bin/bash", "/bin/sh"];

/// Unix constants and lookups.
#[derive(Debug, Default, Clone, Copy)]
pub struct UnixPlatform;

impl UnixPlatform {
    pub fn new() -> Self {
        Self
    }
}

impl PlatformProfile for UnixPlatform {
    fn name(&self) -> &'static str {
        if cfg!(target_os = "macos") {
            "macOS"
        } else {
            "Linux"
        }
    }

    fn default_shell(&self) -> SpawnSpec {
        let program = std::env::var("SHELL")
            .ok()
            .filter(|shell| !shell.trim().is_empty())
            .filter(|shell| std::path::Path::new(shell).exists())
            .unwrap_or_else(|| {
                SHELL_FALLBACKS
                    .iter()
                    .find(|candidate| std::path::Path::new(candidate).exists())
                    .unwrap_or(&"/bin/sh")
                    .to_string()
            });

        // `-l` so the shell reads login files: herdr and the agents live in
        // /opt/homebrew/bin, which is not on a non-login PATH.
        SpawnSpec::program(program).arg("-l")
    }

    fn monospace_family(&self) -> &'static str {
        if cfg!(target_os = "macos") {
            "Menlo"
        } else {
            "DejaVu Sans Mono"
        }
    }
}

/// Reads the process table with `ps`.
///
/// `ps` rather than a crate: it is present on every Unix, needs no dependency,
/// and the output is trivial to parse. The Windows adapter uses
/// `CreateToolhelp32Snapshot` to produce the same [`ProcessInfo`] list.
#[derive(Debug, Default, Clone, Copy)]
pub struct UnixProcessInspector;

impl UnixProcessInspector {
    pub fn new() -> Self {
        Self
    }

    /// Parses `ps -Ao pid=,ppid=,comm=` output. Split out so it can be tested
    /// against captured output instead of the live process table.
    fn parse(output: &str) -> Vec<ProcessInfo> {
        output
            .lines()
            .filter_map(|line| {
                let mut fields = line.split_whitespace();
                let pid = fields.next()?.parse().ok()?;
                let parent_pid = fields.next()?.parse().ok()?;
                // `comm` can contain spaces and a path; keep the basename.
                let rest = fields.collect::<Vec<_>>().join(" ");
                let name = rest.rsplit('/').next().unwrap_or(&rest).trim().to_string();
                if name.is_empty() {
                    return None;
                }
                Some(ProcessInfo {
                    pid,
                    parent_pid,
                    name,
                })
            })
            .collect()
    }
}

impl ProcessInspector for UnixProcessInspector {
    fn snapshot(&self) -> Result<Vec<ProcessInfo>> {
        let output = Command::new("ps")
            .args(["-Ao", "pid=,ppid=,comm="])
            .output()
            .context("run ps")?;

        Ok(Self::parse(&String::from_utf8_lossy(&output.stdout)))
    }
}

#[cfg(test)]
mod tests {
    use herdr_bridge_core::platform::descendants_of;

    use super::*;

    #[test]
    fn parses_ps_output_into_processes() {
        let sample = "\
    1     0 /sbin/launchd
  501     1 /bin/zsh
  777   501 /opt/homebrew/bin/node
";
        let processes = UnixProcessInspector::parse(sample);
        assert_eq!(processes.len(), 3);
        assert_eq!(processes[1].pid, 501);
        assert_eq!(processes[1].parent_pid, 1);
        // The path is stripped down to the executable name.
        assert_eq!(processes[2].name, "node");
    }

    #[test]
    fn parse_skips_malformed_lines() {
        let sample = "not a process row\n  1  0 /sbin/launchd\n\n";
        let processes = UnixProcessInspector::parse(sample);
        assert_eq!(processes.len(), 1);
        assert_eq!(processes[0].name, "launchd");
    }

    #[test]
    fn parsed_output_feeds_the_core_tree_walk() {
        let sample = "  1 0 launchd\n 501 1 zsh\n 777 501 node\n 888 777 rg\n";
        let processes = UnixProcessInspector::parse(sample);
        let names: Vec<String> = descendants_of(&processes, 501)
            .into_iter()
            .map(|p| p.name)
            .collect();
        assert!(names.contains(&"node".to_string()));
        assert!(names.contains(&"rg".to_string()));
    }

    #[test]
    fn snapshot_sees_this_test_process() {
        let processes = UnixProcessInspector::new().snapshot().expect("snapshot");
        let me = std::process::id();
        assert!(
            processes.iter().any(|p| p.pid == me),
            "ps output should include the current process"
        );
    }

    #[test]
    fn default_shell_is_a_login_shell_that_exists() {
        let spec = UnixPlatform::new().default_shell();
        assert!(std::path::Path::new(&spec.program).exists());
        assert_eq!(spec.args, ["-l"]);
    }
}
