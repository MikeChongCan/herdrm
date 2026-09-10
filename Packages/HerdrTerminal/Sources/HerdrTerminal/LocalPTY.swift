#if os(macOS)
import Darwin
import Foundation

/// A login PTY around `forkpty` + `execve`. All callbacks run on the main queue.
final class LocalPTY {
    var onData: ((Data) -> Void)?
    var onExit: ((Int32?) -> Void)?

    private var master: Int32 = -1
    private var childPid: pid_t = 0
    private var source: DispatchSourceRead?
    private let ioQueue = DispatchQueue(label: "dev.bybee.herdrm.pty")
    private var didExit = false

    var processID: pid_t { childPid }

    func start(
        executable: String,
        args: [String],
        environment: [String],
        cols: Int,
        rows: Int
    ) throws {
        terminate()
        var window = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, cols)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        var masterFD: Int32 = -1
        let pid = forkpty(&masterFD, nil, nil, &window)
        if pid < 0 {
            throw POSIXError.fromErrno()
        }
        if pid == 0 {
            executable.withCString { exe in
                let argv = ([executable] + args).map { strdup($0) } + [nil]
                let envp = environment.map { strdup($0) } + [nil]
                execve(exe, argv, envp)
                _exit(127)
            }
        }
        master = masterFD
        childPid = pid
        let fd = masterFD
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16 * 1024)
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                let data = Data(buffer.prefix(n))
                DispatchQueue.main.async { self?.onData?(data) }
            } else {
                self?.reap()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        self.source = source
        source.resume()
    }

    func write(_ data: Data) {
        guard master >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(master, base + offset, raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    func resize(cols: Int, rows: Int, cellWidth: Int, cellHeight: Int) {
        guard master >= 0 else { return }
        var window = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, cols)),
            ws_xpixel: UInt16(min(65535, max(0, cols * cellWidth))),
            ws_ypixel: UInt16(min(65535, max(0, rows * cellHeight)))
        )
        _ = ioctl(master, TIOCSWINSZ, &window)
    }

    func terminate() {
        source?.cancel()
        source = nil
        master = -1
        if childPid > 0 {
            kill(childPid, SIGHUP)
            ioQueue.async { [pid = childPid] in
                var status: Int32 = 0
                for _ in 0..<20 {
                    if waitpid(pid, &status, WNOHANG) != 0 { return }
                    usleep(100_000)
                }
                kill(pid, SIGKILL)
                waitpid(pid, &status, 0)
            }
            childPid = 0
        }
    }

    private func reap() {
        guard !didExit else { return }
        didExit = true
        var status: Int32 = 0
        let pid = childPid
        if pid > 0 {
            waitpid(pid, &status, 0)
        }
        let code: Int32? = (status & 0x7f) == 0 ? ((status >> 8) & 0xff) : nil
        DispatchQueue.main.async { [weak self] in
            self?.onExit?(code)
        }
        source?.cancel()
        source = nil
        master = -1
        childPid = 0
    }

    deinit {
        terminate()
    }
}

private extension POSIXError {
    static func fromErrno() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
    }
}
#endif
