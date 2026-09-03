//! Windows shell selection.
//!
//! Deliberately free of `#[cfg(windows)]` and of any syscall: the decision
//! ("prefer PowerShell 7, fall back to Windows PowerShell, then cmd") is
//! ordinary logic, and keeping it here means it is covered by `cargo test` on a
//! Mac. Only the "does this file exist" probe is platform work, and it is
//! injected.

use herdr_bridge_core::platform::SpawnSpec;

/// Candidate shells, best first.
///
/// PowerShell 7 (`pwsh.exe`) is preferred because it is what agent tooling
/// expects; `powershell.exe` (5.1) ships with the OS; `cmd.exe` always exists
/// and is the last resort.
pub const SHELL_CANDIDATES: &[&str] = &[
    r"C:\Program Files\PowerShell\7\pwsh.exe",
    r"C:\Program Files\PowerShell\7-preview\pwsh.exe",
    r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe",
    r"C:\Windows\System32\cmd.exe",
];

/// Picks the first candidate that `exists` accepts, and gives it the right
/// arguments.
///
/// Falls back to bare `cmd.exe` (resolved via PATH) when nothing matches, so
/// the bridge always has something to spawn.
pub fn choose_shell(candidates: &[&str], exists: impl Fn(&str) -> bool) -> SpawnSpec {
    let program = candidates
        .iter()
        .find(|candidate| exists(candidate))
        .map(|candidate| candidate.to_string())
        .unwrap_or_else(|| "cmd.exe".to_string());

    shell_spec(&program)
}

/// Builds the spawn spec for a chosen shell, including its no-banner flag.
fn shell_spec(program: &str) -> SpawnSpec {
    let file_name = program
        .rsplit(['\\', '/'])
        .next()
        .unwrap_or(program)
        .to_ascii_lowercase();

    let spec = SpawnSpec::program(program);
    match file_name.as_str() {
        // Suppress the startup banner so the pane opens on a clean prompt.
        "pwsh.exe" | "powershell.exe" => spec.arg("-NoLogo"),
        _ => spec,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prefers_powershell_7_when_present() {
        let spec = choose_shell(SHELL_CANDIDATES, |_| true);
        assert_eq!(spec.program, r"C:\Program Files\PowerShell\7\pwsh.exe");
        assert_eq!(spec.args, ["-NoLogo"]);
    }

    #[test]
    fn falls_back_to_windows_powershell() {
        let spec = choose_shell(SHELL_CANDIDATES, |path| path.contains("v1.0"));
        assert!(spec.program.ends_with("powershell.exe"));
        assert_eq!(spec.args, ["-NoLogo"]);
    }

    #[test]
    fn falls_back_to_cmd_without_a_banner_flag() {
        let spec = choose_shell(SHELL_CANDIDATES, |path| path.ends_with("cmd.exe"));
        assert!(spec.program.ends_with("cmd.exe"));
        // cmd.exe has no -NoLogo; passing one would be an error, not a no-op.
        assert!(spec.args.is_empty());
    }

    #[test]
    fn falls_back_to_bare_cmd_when_nothing_exists() {
        let spec = choose_shell(SHELL_CANDIDATES, |_| false);
        assert_eq!(spec.program, "cmd.exe");
        assert!(spec.args.is_empty());
    }

    #[test]
    fn handles_forward_slash_paths() {
        let spec = choose_shell(&["C:/Program Files/PowerShell/7/pwsh.exe"], |_| true);
        assert_eq!(spec.args, ["-NoLogo"]);
    }
}
