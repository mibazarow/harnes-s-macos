import Darwin
import Foundation

extension ToolRegistry {
// MARK: - Shell and process

    /// How much of each stream a command may return. The files stay on disk until the
    /// command exits; only this much is read back into memory.
    private static let stdoutLimit = 22_000
    private static let stderrLimit = 8_000

    func runShell(_ args: [String: Any]) async throws -> ToolResult {
        guard let command = args["command"] as? String else { return .fail("command обязателен") }
        let timeout = TimeInterval(min(max((args["timeout_ms"] as? Int) ?? 60_000, 1_000), 600_000)) / 1_000
        let cancellation = ProcessCancellation()
        let workspace = self.workspace

        // The detached task does not inherit cancellation, so the handler has to reach
        // the child through the shared box: otherwise Stop returns to the user while a
        // build keeps running until its own timeout.
        let output = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try Self.runSync(command, cwd: workspace, timeout: timeout, cancellation: cancellation)
            }.value
        } onCancel: {
            cancellation.cancel()
        }

        // The two stream caps add up to 30 000, so the reply keeps the documented
        // ceiling without cutting the truncation note itself.
        return .ok(output.isEmpty ? "(команда выполнена, вывода нет)" : output)
    }

    /// Runs a command to completion or timeout and returns `exit N` plus its output.
    ///
    /// The child is spawned into its own process group (`POSIX_SPAWN_SETPGROUP`), so a
    /// timeout kills the whole tree with one `kill(-pid, SIGKILL)`. `Process.terminate()`
    /// only signals the `zsh` wrapper; build tools and servers it started keep running.
    static func runSync(
        _ command: String,
        cwd: URL,
        timeout: TimeInterval,
        cancellation: ProcessCancellation? = nil
    ) throws -> String {
        // Output goes to files, not pipes: a command that prints more than the pipe
        // buffer holds would block on write, never exit, and die on the timeout with
        // its output lost.
        let directory = FileManager.default.temporaryDirectory
        let outURL = directory.appendingPathComponent("harness-out-\(UUID().uuidString)")
        let errURL = directory.appendingPathComponent("harness-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }

        // The imported posix_spawn types are optional opaque pointers on this SDK: the
        // _init call allocates and fills them, so they are declared optional here.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // /dev/null on stdin: an interactive prompt would otherwise wait for input that
        // never comes and burn the whole timeout.
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, outURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addopen(&actions, 2, errURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        posix_spawn_file_actions_addchdir_np(&actions, cwd.path)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        // pgroup 0 means "use the child's own pid", which makes it the group leader.
        posix_spawnattr_setpgroup(&attributes, 0)

        var argv: [UnsafeMutablePointer<CChar>?] = [
            strdup("/bin/zsh"), strdup("-lc"), strdup(command), nil
        ]
        defer { argv.forEach { pointer in if let pointer { free(pointer) } } }

        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, "/bin/zsh", &actions, &attributes, &argv, environ)
        guard spawned == 0 else {
            throw NSError(domain: "Harness", code: Int(spawned), userInfo: [
                NSLocalizedDescriptionKey: "Не удалось запустить команду (errno \(spawned))."
            ])
        }

        let done = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { done.signal() }
        source.resume()
        defer { source.cancel() }

        cancellation?.attach(pid: pid)

        let deadline = Date().addingTimeInterval(timeout)
        var stopped: StopReason?
        while true {
            if done.wait(timeout: .now() + 0.05) == .success { break }
            if cancellation?.isCancelled == true {
                stopped = .cancelled
                break
            }
            if Date() >= deadline {
                stopped = .timedOut
                break
            }
        }

        // The process may have exited between the last poll and the cancel() call, in
        // which case the semaphore won and the loop broke without seeing the flag.
        if stopped == nil, cancellation?.isCancelled == true {
            stopped = .cancelled
        }

        var status: Int32 = 0
        if let stopped {
            // Give the already-reaped child no extra signal; only a live one needs the
            // group kill. The group id equals the leader pid, so -pid is the whole tree.
            if waitpid(pid, &status, WNOHANG) == 0 {
                kill(-pid, SIGKILL)
                _ = done.wait(timeout: .now() + 2)
                waitpid(pid, &status, 0)
            }
            source.cancel()
            switch stopped {
            case .cancelled:
                throw CancellationError()
            case .timedOut:
                throw NSError(domain: "Harness", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Команда превысила таймаут \(Int(timeout)) с и была остановлена."
                ])
            }
        }

        waitpid(pid, &status, 0)
        source.cancel()

        let out = readHead(outURL, limit: stdoutLimit)
        let err = readHead(errURL, limit: stderrLimit)
        let merged = [out, err].filter { !$0.isEmpty }.joined(separator: "\n--- stderr ---\n")
        let exitCode = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        return "exit \(exitCode)\n" + merged
    }

    private enum StopReason {
        case timedOut
        case cancelled
    }

    /// Reads at most `limit` bytes and says so when the file is longer.
    private static func readHead(_ url: URL, limit: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: limit)) ?? Data()
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        var text = String(decoding: data, as: UTF8.self)
        if size > data.count {
            text += "\n[вывод обрезан на \(limit) байт из \(size)]"
        }
        return text
    }

    /// Runs a short command off the cooperative pool.
    ///
    /// `runSync` blocks until the process exits. Called directly from an async tool it
    /// pins a pool thread for up to a minute, and several such calls starve the rest of
    /// the run. `runShell` already detaches; every other command tool goes through here.
    static func runDetached(_ command: String, cwd: URL, timeout: TimeInterval) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try runSync(command, cwd: cwd, timeout: timeout)
        }.value
    }

    /// Splits the `exit N` header off `runSync` output.
    ///
    /// Stripping the text with `replacingOccurrences` used to remove a legitimate
    /// `exit 1` line from the command's own output as well.
    static func splitExit(_ output: String) -> (status: Int32, body: String) {
        let parts = output.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = parts.first, first.hasPrefix("exit "),
              let code = Int32(first.dropFirst(5)) else {
            return (0, output)
        }
        return (code, parts.count > 1 ? String(parts[1]) : "")
    }

    /// Absolute paths first: a GUI app does not inherit the shell's PATH, so a bare
    /// `rg` works in Terminal and fails inside the app.
    static let ripgrepPath: String? = {
        let candidates = [
            "/opt/homebrew/bin/rg",
            "/usr/local/bin/rg",
            "/usr/bin/rg"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Shared handle between the awaiting task and the synchronous runner.
///
/// A detached task cannot see the parent's cancellation, and the runner is blocked in
/// `waitpid`-adjacent code, so cancellation arrives as a flag plus a signal.
final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func attach(pid: pid_t) {
        lock.lock()
        self.pid = pid
        let alreadyCancelled = cancelled
        lock.unlock()
        // Cancelled before the spawn finished: kill it now, nobody will check again.
        if alreadyCancelled { kill(-pid, SIGKILL) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let target = pid
        lock.unlock()
        if target > 0 { kill(-target, SIGKILL) }
    }
}
