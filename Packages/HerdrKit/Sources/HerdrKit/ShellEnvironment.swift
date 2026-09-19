#if os(macOS)
import Darwin
import Foundation

/// Login + interactive shell environment for a Finder-launched GUI process.
///
/// LaunchServices gives herdrm `/usr/bin:/bin:/usr/sbin:/sbin`. The PATH that actually
/// has `codex`, `claude`, `node`, and fnm/nvm/mise shims lives in the user's shell
/// startup files, which the desktop never executes. This type asks a real shell to
/// run those files as code (not by grepping `export PATH=`), snapshots the exported
/// environment once, and reuses it for both lookup and spawn.
///
/// Probe shape (mirrors Waku): tempfile + `env -0`, stdin/out/err discarded,
/// independent session (so timeout can SIGKILL the group without hanging zsh -i),
/// 3 s interactive then login-only fallback, 5 s round
/// budget, SIGKILL the group on timeout. Failure is empty, not an error — lookup
/// still walks the GUI PATH and the well-known install prefixes.
public struct ShellEnvironment: Sendable, Equatable {
    public let variables: [String: String]

    public static let empty = ShellEnvironment(variables: [:])

    public init(variables: [String: String]) {
        self.variables = variables
    }

    public subscript(_ name: String) -> String? { variables[name] }

    /// First caller spawns a login shell (must not run on the UI thread); later
    /// callers share the snapshot. A failed probe is cached as empty so we never
    /// retry a hanging `.zshrc` on every New Agent sheet.
    public static func ensure() async -> ShellEnvironment {
        await Cache.shared.ensure()
    }

    /// Snapshot from a completed `ensure()`, or nil if nobody has probed yet.
    public static var cached: ShellEnvironment? { Cache.shared.cached }

    /// Probe that does not touch the process-wide cache. `ensure()` calls this;
    /// tests call it with an isolated `HOME` / `SHELL`.
    ///
    /// `interactiveTimeout` is the budget for `-i -l` (zsh only reads `.zshrc`
    /// when interactive). The leftover of `roundTimeout` is spent on `-l`.
    public static func capture(
        from base: [String: String] = ProcessInfo.processInfo.environment,
        interactiveTimeout: TimeInterval = 3,
        roundTimeout: TimeInterval = 5
    ) -> ShellEnvironment {
        let roundDeadline = Date().addingTimeInterval(max(roundTimeout, 0.05))
        for shell in shellCandidates(from: base) {
            let remaining = roundDeadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            if let snapshot = captureAttempt(
                shell: shell,
                arguments: ["-i", "-l", "-c", captureCommand],
                base: base,
                timeout: min(interactiveTimeout, remaining)
            ) {
                return snapshot
            }
            let leftover = roundDeadline.timeIntervalSinceNow
            guard leftover > 0 else { break }
            if let snapshot = captureAttempt(
                shell: shell,
                arguments: ["-l", "-c", captureCommand],
                base: base,
                timeout: leftover
            ) {
                return snapshot
            }
        }
        return .empty
    }

    // MARK: - Lookup

    /// Directories searched for agent (and herdr) binaries, first match wins.
    /// Order: login-shell PATH, GUI process PATH, user-level prefixes, system
    /// prefixes. Duplicates dropped, order kept.
    public func searchDirectories(
        processPath: String? = nil,
        home: String? = nil
    ) -> [String] {
        let process = ProcessInfo.processInfo.environment
        let homeDirectory = home
            ?? variables["HOME"]
            ?? process["HOME"]
            ?? NSHomeDirectory()
        let inheritedPath = processPath ?? process["PATH"] ?? ""

        var directories: [String] = []
        var seen = Set<String>()
        func append(_ raw: String) {
            var path = raw
            while path.count > 1, path.hasSuffix("/") { path.removeLast() }
            guard !path.isEmpty, seen.insert(path).inserted else { return }
            directories.append(path)
        }

        for directory in Self.splitPath(variables["PATH"]) { append(directory) }
        for directory in Self.splitPath(inheritedPath) { append(directory) }
        for directory in Self.wellKnownDirectories(home: homeDirectory) { append(directory) }
        return directories
    }

    /// Well-known Unix install prefixes used when the login-shell probe fails
    /// (or as a backstop when it succeeds but PATH is incomplete).
    public static func wellKnownDirectories(home: String) -> [String] {
        [
            "\(home)/.local/bin",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin",
            "\(home)/.local/share/mise/shims",
            "\(home)/.volta/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
    }

    /// Locate `name` on the search path.
    ///
    /// - Bare command (`codex`, `cursor-agent`): walk `searchDirectories`.
    /// - `~/…`: expand against `HOME`, must already be a file.
    /// - Absolute or relative path: same, no PATH walk.
    ///
    /// Cursor's CLI is `cursor-agent` (not `agent`); callers pass `binaryName(for:)`.
    public func findExecutable(
        _ name: String,
        processPath: String? = nil,
        home: String? = nil
    ) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let homeDirectory = home
            ?? variables["HOME"]
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()

        if trimmed == "~"
            || trimmed.hasPrefix("~/")
            || trimmed.hasPrefix("/")
            || trimmed.contains("/")
        {
            let path = Self.expandPath(trimmed, home: homeDirectory)
            return Self.isRunnableFile(path) ? path : nil
        }

        guard Self.isCommandName(trimmed) else { return nil }
        for directory in searchDirectories(processPath: processPath, home: homeDirectory) {
            let candidate = (directory as NSString).appendingPathComponent(trimmed)
            if Self.isRunnableFile(candidate) { return candidate }
        }
        return nil
    }

    /// Environment handed to a child that will exec an agent shim (`#!/usr/bin/env node`,
    /// bun, nvm wrappers). The whole captured block is used (so `NVM_DIR` / `FNM_*`
    /// survive); `PATH` is replaced with the same directory list lookup used, plus
    /// the binary's own directory last so a match outside PATH still finds `node`
    /// sitting next to it without reordering the user's PATH.
    public func launchEnvironment(
        binary: String? = nil,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = variables.isEmpty ? processEnvironment : variables
        var directories = searchDirectories(
            processPath: processEnvironment["PATH"],
            home: environment["HOME"] ?? processEnvironment["HOME"]
        )
        if let binary {
            let directory = (binary as NSString).deletingLastPathComponent
            if !directory.isEmpty { directories.append(directory) }
        }
        environment["PATH"] = directories.joined(separator: ":")
        return environment
    }

    // MARK: - Capture

    static let captureFileKey = "HERDRM_SHELL_ENV_CAPTURE_FILE"

    static let injectedKeys: Set<String> = [
        captureFileKey,
        "DISABLE_AUTO_UPDATE",
        "DISABLE_UPDATE_PROMPT",
        "ZSH_DISABLE_COMPFIX",
        "ZSH_TMUX_AUTOSTART",
        "ZSH_TMUX_AUTOSTARTED",
    ]

    private static let captureCommand =
        "/usr/bin/env -0 > \"$\(captureFileKey)\""

    /// `$SHELL` first (the rc that produced the user's PATH), then passwd
    /// (`chsh`), then platform fallbacks. The in-app terminal uses passwd first
    /// because that is the shell the user chose; detection wants the shell that
    /// currently owns PATH.
    static func shellCandidates(from environment: [String: String]) -> [String] {
        var shells: [String] = []
        func append(_ raw: String?) {
            let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !path.isEmpty, isRunnableFile(path), !shells.contains(path) else { return }
            shells.append(path)
        }
        append(environment["SHELL"])
        append(passwdShell())
        append("/bin/zsh")
        append("/bin/bash")
        append("/bin/sh")
        return shells
    }

    static func parseNulEnvironment(_ data: Data) -> [String: String] {
        var environment: [String: String] = [:]
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0) ?? data.endIndex
            let entry = data[start..<end]
            start = end < data.endIndex ? data.index(after: end) : end
            guard !entry.isEmpty,
                  let separator = entry.firstIndex(of: UInt8(ascii: "=")),
                  separator > entry.startIndex
            else { continue }
            let name = decodeEnvBytes(Data(entry[..<separator]))
            guard !injectedKeys.contains(name) else { continue }
            environment[name] = decodeEnvBytes(Data(entry[entry.index(after: separator)...]))
        }
        return environment
    }

    // MARK: - Internals

    private static func captureAttempt(
        shell: String,
        arguments: [String],
        base: [String: String],
        timeout: TimeInterval
    ) -> ShellEnvironment? {
        guard let file = exclusiveCaptureFile(tmpdir: base["TMPDIR"]) else { return nil }
        defer { unlink(file) }

        var environment = base
        environment[captureFileKey] = file
        environment["DISABLE_AUTO_UPDATE"] = "true"
        environment["DISABLE_UPDATE_PROMPT"] = "true"
        environment["ZSH_DISABLE_COMPFIX"] = "true"
        environment["ZSH_TMUX_AUTOSTART"] = "false"
        environment["ZSH_TMUX_AUTOSTARTED"] = "true"

        guard let status = TimedProcess.run(
            executable: shell,
            arguments: arguments,
            environment: environment,
            timeout: timeout
        ), status == 0 else { return nil }

        guard let data = FileManager.default.contents(atPath: file) else { return nil }
        let parsed = parseNulEnvironment(data)
        guard parsed["PATH"] != nil else { return nil }
        return ShellEnvironment(variables: parsed)
    }

    private static func exclusiveCaptureFile(tmpdir: String?) -> String? {
        let root = (tmpdir?.isEmpty == false ? tmpdir! : NSTemporaryDirectory())
        let directory = root.hasSuffix("/") ? root : root + "/"
        for _ in 0..<8 {
            let path = "\(directory).herdrm-shell-env-\(getpid())-\(UUID().uuidString.prefix(8))"
            let fd = open(path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            guard fd >= 0 else { continue }
            fchmod(fd, 0o600)
            close(fd)
            return path
        }
        return nil
    }

    private static func splitPath(_ path: String?) -> [String] {
        guard let path, !path.isEmpty else { return [] }
        return path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }

    private static func expandPath(_ path: String, home: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + "/" + path.dropFirst(2) }
        if path.hasPrefix("/") { return path }
        return (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(path)
    }

    static func isCommandName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isLetter || $0.isNumber || "-_+.".contains($0) }
    }

    static func isRunnableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    /// Account login shell from the password database. `geteuid()` so a
    /// setuid-adjacent launch still sees the user who should own PATH.
    static func passwdShell() -> String? {
        var pwd = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 16_384)
        let code = buffer.withUnsafeMutableBufferPointer { buf in
            getpwuid_r(geteuid(), &pwd, buf.baseAddress, buf.count, &result)
        }
        guard code == 0, result != nil else { return nil }
        let shell = String(cString: pwd.pw_shell).trimmingCharacters(in: .whitespaces)
        return shell.isEmpty ? nil : shell
    }

    private static func decodeEnvBytes(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}

// MARK: - Process-wide cache

/// `OnceLock` analogue: the probe is expensive and `.zshrc` is not re-entrant-safe
/// to run per provider. Locking stays off the async path so this builds under
/// Swift 6's `NSLock` rule.
private final class Cache: @unchecked Sendable {
    static let shared = Cache()

    private let lock = NSLock()
    private var snapshot: ShellEnvironment?
    private var inFlight: Task<ShellEnvironment, Never>?

    var cached: ShellEnvironment? {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    func ensure() async -> ShellEnvironment {
        if let snapshot = cached { return snapshot }
        return await probeTask().value
    }

    private func probeTask() -> Task<ShellEnvironment, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let snapshot {
            return Task { snapshot }
        }
        if let inFlight { return inFlight }
        let task = Task.detached(priority: .utility) { [self] in
            let captured = ShellEnvironment.capture()
            self.store(captured)
            return captured
        }
        inFlight = task
        return task
    }

    private func store(_ captured: ShellEnvironment) {
        lock.lock()
        snapshot = captured
        inFlight = nil
        lock.unlock()
    }
}

// MARK: - Timed posix_spawn

/// Foundation `Process` is the wrong primitive here: we need a new session (so a
/// timed-out nvm/tmux child dies with the shell, and zsh -i does not hang in
/// `tcsetpgrp`), a child signal mask that unblocks `SIGCHLD` (libdispatch / some
/// UI runtimes block it and zsh job control then hangs), and stdin/out/err on
/// `/dev/null` so rc banners never mix with the snapshot. Capture itself is a
/// tempfile.
private enum TimedProcess {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) -> Int32? {
        let argvStrings = [executable] + arguments
        let envStrings = environment.map { "\($0.key)=\($0.value)" }

        return withCStrings(argvStrings) { argv in
            withCStrings(envStrings) { envp in
                spawnAndWait(
                    executable: executable,
                    argv: argv,
                    envp: envp,
                    timeout: timeout
                )
            }
        }
    }

    private static func spawnAndWait(
        executable: String,
        argv: UnsafePointer<UnsafeMutablePointer<CChar>?>,
        envp: UnsafePointer<UnsafeMutablePointer<CChar>?>,
        timeout: TimeInterval
    ) -> Int32? {
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        _ = posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        _ = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        _ = posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attr) }

        // SETSID, not SETPGROUP: zsh -i + setpgrp with no controlling tty
        // blocks forever in job control (`tcsetpgrp`). A new session has no
        // tty, so -i still reads `.zshrc` and `-c` returns. The child is a
        // session leader, so timeout can still SIGKILL the whole group.
        let flags = Int16(bitPattern: UInt16(
            POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        ))
        posix_spawnattr_setflags(&attr, flags)

        // Disclaim herdrm's TCC responsibility for this probe: it runs the user's
        // `.zshrc` / `.zprofile`, which routinely touch other apps' data (version
        // managers, history sync, plugin managers), and those accesses should not
        // prompt as herdrm. See `ResponsibilityDisclaim` (issue #87).
        ResponsibilityDisclaim.apply(to: &attr)

        var empty = sigset_t()
        sigemptyset(&empty)
        posix_spawnattr_setsigmask(&attr, &empty)

        var pid: pid_t = 0
        let spawned = executable.withCString { path in
            posix_spawn(&pid, path, &actions, &attr, argv, envp)
        }
        guard spawned == 0 else { return nil }

        let deadline = Date().addingTimeInterval(max(timeout, 0.05))
        var status: Int32 = 0
        while true {
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                // Darwin's WIFEXITED / WEXITSTATUS are function-like macros Swift
                // does not import. `_WSTATUS == 0` means a normal exit.
                let terminated = status & 0o177
                return terminated == 0 ? (status >> 8) & 0xff : nil
            }
            if waited < 0 { return nil }
            if Date() >= deadline {
                kill(-pid, SIGKILL)
                waitpid(pid, &status, 0)
                return nil
            }
            usleep(20_000)
        }
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
