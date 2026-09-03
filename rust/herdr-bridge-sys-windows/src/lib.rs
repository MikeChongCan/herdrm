//! Windows adapter: default shell, process inspection, and Job Object cleanup.
//!
//! # How this crate stays honest on a Mac
//!
//! The crate is a workspace member on every host, but the Win32 code is
//! `#[cfg(windows)]` and the `windows-sys` dependency is target-gated, so
//! `cargo build --workspace` on macOS compiles this down to just [`shell`] —
//! which is pure logic and *does* run under `cargo test` on macOS.
//!
//! What that buys: the shell-selection policy is verified anywhere. What it
//! does not buy: the Toolhelp and Job Object code below is only type-checked by
//! a Windows compiler, so the CI matrix must include `windows-latest`. See
//! `docs/WINDOWS_SUPPORT_PLAN.md` §3.6.D for the rest of the list.

pub mod shell;

use herdr_bridge_core::platform::{PlatformProfile, SpawnSpec};

/// Windows constants and lookups.
#[derive(Debug, Default, Clone, Copy)]
pub struct WindowsPlatform;

impl WindowsPlatform {
    pub fn new() -> Self {
        Self
    }
}

impl PlatformProfile for WindowsPlatform {
    fn name(&self) -> &'static str {
        "Windows"
    }

    fn default_shell(&self) -> SpawnSpec {
        shell::choose_shell(shell::SHELL_CANDIDATES, |path| {
            std::path::Path::new(path).exists()
        })
    }

    fn monospace_family(&self) -> &'static str {
        // Ships with Windows Terminal and Windows 11.
        "Cascadia Mono"
    }
}

#[cfg(windows)]
mod toolhelp {
    use anyhow::{bail, Result};
    use herdr_bridge_core::platform::{ProcessInfo, ProcessInspector};
    use windows_sys::Win32::Foundation::{CloseHandle, INVALID_HANDLE_VALUE};
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{
        CreateToolhelp32Snapshot, Process32FirstW, Process32NextW, PROCESSENTRY32W,
        TH32CS_SNAPPROCESS,
    };

    /// Reads the process table via `CreateToolhelp32Snapshot`, the Windows
    /// counterpart to the Unix adapter's `ps`.
    #[derive(Debug, Default, Clone, Copy)]
    pub struct WindowsProcessInspector;

    impl WindowsProcessInspector {
        pub fn new() -> Self {
            Self
        }
    }

    /// Owns a snapshot handle so it is closed on every exit path, including an
    /// early return or a panic.
    struct SnapshotHandle(windows_sys::Win32::Foundation::HANDLE);

    impl Drop for SnapshotHandle {
        fn drop(&mut self) {
            // SAFETY: the handle is valid — construction rejects
            // INVALID_HANDLE_VALUE — and this runs exactly once.
            unsafe {
                CloseHandle(self.0);
            }
        }
    }

    /// Decodes a NUL-terminated UTF-16 `szExeFile` field.
    fn exe_name(raw: &[u16]) -> String {
        let end = raw.iter().position(|&c| c == 0).unwrap_or(raw.len());
        String::from_utf16_lossy(&raw[..end])
    }

    impl ProcessInspector for WindowsProcessInspector {
        fn snapshot(&self) -> Result<Vec<ProcessInfo>> {
            // SAFETY: a well-formed Toolhelp call; the returned handle is
            // checked before use and owned by SnapshotHandle.
            let handle = unsafe { CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) };
            if handle == INVALID_HANDLE_VALUE {
                bail!("CreateToolhelp32Snapshot failed");
            }
            let handle = SnapshotHandle(handle);

            let mut entry: PROCESSENTRY32W = unsafe { std::mem::zeroed() };
            // Required by the API: the struct must announce its own size.
            entry.dwSize = std::mem::size_of::<PROCESSENTRY32W>() as u32;

            let mut processes = Vec::new();

            // SAFETY: `entry` is zeroed, correctly sized, and lives for the
            // whole walk; the handle is valid.
            let mut ok = unsafe { Process32FirstW(handle.0, &mut entry) };
            while ok != 0 {
                processes.push(ProcessInfo {
                    pid: entry.th32ProcessID,
                    parent_pid: entry.th32ParentProcessID,
                    name: exe_name(&entry.szExeFile),
                });
                ok = unsafe { Process32NextW(handle.0, &mut entry) };
            }

            Ok(processes)
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn exe_name_stops_at_the_nul_terminator() {
            let mut raw = [0u16; 260];
            for (i, c) in "pwsh.exe".encode_utf16().enumerate() {
                raw[i] = c;
            }
            assert_eq!(exe_name(&raw), "pwsh.exe");
        }

        #[test]
        fn snapshot_sees_this_test_process() {
            let processes = WindowsProcessInspector::new().snapshot().expect("snapshot");
            assert!(processes.iter().any(|p| p.pid == std::process::id()));
        }
    }
}

#[cfg(windows)]
pub use toolhelp::WindowsProcessInspector;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn platform_reports_windows_and_a_bundled_monospace_font() {
        let platform = WindowsPlatform::new();
        assert_eq!(platform.name(), "Windows");
        assert_eq!(platform.monospace_family(), "Cascadia Mono");
    }

    #[test]
    fn default_shell_always_yields_something_spawnable() {
        // On macOS none of the candidate paths exist, which exercises the
        // fallback; on Windows this picks a real shell.
        let spec = WindowsPlatform::new().default_shell();
        assert!(!spec.program.is_empty());
    }
}
