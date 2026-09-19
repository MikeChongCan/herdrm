#if os(macOS)
import Darwin
import Foundation

/// macOS attributes a child's TCC prompts and Launch Services "responsibility" to
/// the nearest *responsible* ancestor. For a process herdrm `posix_spawn`s, that
/// responsible process is herdrm — so the `herdr server` we start on demand, and
/// every coding agent it goes on to run, answer their permission dialogs *as
/// herdrm*. That is why users see "herdrm would like to access data from other
/// apps" while an agent (not herdrm) reads a file (issue #87), and why revoking
/// that grant would break the agents rather than herdrm.
///
/// Disclaiming responsibility at spawn makes the child its own responsible
/// process, so it — and the tree beneath it — prompts as itself. Every terminal
/// emulator (iTerm2, Ghostty, WezTerm, Terminal.app) makes the same call for the
/// programs it launches, for exactly this reason.
///
/// `responsibility_spawnattrs_setdisclaim` is a private libSystem symbol, so it is
/// resolved at runtime with `dlsym`. If it ever vanishes the spawn still works —
/// just without the disclaim, i.e. today's behavior.
enum ResponsibilityDisclaim {
    private typealias Fn = @convention(c) (
        UnsafeMutablePointer<posix_spawnattr_t?>, Int32
    ) -> Int32

    private static let fn: Fn? = {
        // RTLD_DEFAULT searches every image already loaded in the process.
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "responsibility_spawnattrs_setdisclaim"
        ) else { return nil }
        return unsafeBitCast(symbol, to: Fn.self)
    }()

    /// Best effort: a missing symbol or a non-zero return is ignored — the caller
    /// still spawns, only without the disclaim.
    static func apply(to attr: inout posix_spawnattr_t?) {
        _ = fn?(&attr, 1)
    }
}

/// Spawns a long-lived helper (the on-demand `herdr server`) detached from
/// herdrm's session and disclaimed of herdrm's TCC responsibility. stdin comes
/// from `/dev/null`; stdout and stderr are appended to `logPath` (a pipe would
/// stall the daemon once its buffer filled). The child is never reaped here — it
/// is meant to outlive us and launchd reparents it when herdrm exits.
enum DetachedSpawn {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        logPath: String
    ) -> pid_t? {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(
            &actions, STDOUT_FILENO, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o644
        )
        posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO)

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }
        // SETSID: a daemon that outlives herdrm must not sit in herdrm's session
        // or share a controlling terminal. It already has none, so -i/job control
        // is not a concern here.
        posix_spawnattr_setflags(&attr, Int16(bitPattern: UInt16(POSIX_SPAWN_SETSID)))
        ResponsibilityDisclaim.apply(to: &attr)

        let argv = [executable] + arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let spawned = withCStrings(argv) { argvPointer in
            withCStrings(envp) { envpPointer in
                executable.withCString { path in
                    posix_spawn(&pid, path, &actions, &attr, argvPointer, envpPointer)
                }
            }
        }
        return spawned == 0 ? pid : nil
    }

    /// Whether `pid` has already exited, reaping it if so. Returns `false` while
    /// the process is still running (`waitpid` == 0), so `!hasExited` reads as
    /// "still running". A running child is never reaped, so it can outlive us.
    static func hasExited(_ pid: pid_t) -> Bool {
        var status: Int32 = 0
        return waitpid(pid, &status, WNOHANG) != 0
    }

    private static func withCStrings<R>(
        _ values: [String],
        _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
        pointers.append(nil)
        defer {
            for pointer in pointers { free(pointer) }
        }
        return pointers.withUnsafeMutableBufferPointer { buffer in
            body(buffer.baseAddress!)
        }
    }
}
#endif  // os(macOS)
