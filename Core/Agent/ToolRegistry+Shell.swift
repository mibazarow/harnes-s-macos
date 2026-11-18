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
        let timeout = TimeInterval(min(max(Self.int(args, "timeout_ms") ?? 60_000, 1_000), 600_000)) / 1_000
        let cancellation = ProcessCancellation()
        let workspace = self.workspace

        // The detached task does not inherit cancellation, so the handler has to reach
        // the child through the shared box: otherwise Stop returns to the user while a
        // build keeps running until its own timeout.
        // R30.5: the claim goes in before the command is sent, so a lost answer can be
        // refused later instead of being repeated.
        let argsHash = OperationLedger.argsHash(command, String(timeout))
        var claimID: Int64?
        if let operations {
            switch try await operations.claim(tool: "bash", argsHash: argsHash) {
            case .refused(let reason):
                return .fail(reason)
            case .allowed(let id):
                claimID = id
            }
        }

        var output: String
        do {
            output = try await withTaskCancellationHandler {
                try await Task.detached(priority: .userInitiated) {
                    try Self.runSync(command, cwd: workspace, timeout: timeout, cancellation: cancellation)
                }.value
            } onCancel: {
                cancellation.cancel()
            }
        } catch {
            // A timeout or a stop means the command was already sent: its effect is
            // unknown, not failed.
            let nsError = error as NSError
            let sent = error is CancellationError
                || (nsError.domain == "Harness" && nsError.code == 1)
            let outcome: OperationOutcome = sent ? .unknown : .failed
            if let claimID { try? await operations?.finish(claimID, outcome: outcome) }
            guard outcome == .unknown else { throw error }
            // The caller still gets an error — the command did not finish — but the text
            // now says the effect is unknown and repeating is forbidden.
            throw NSError(domain: "Harness", code: 2, userInfo: [
                NSLocalizedDescriptionKey: error.localizedDescription + "\n" + (outcome.line ?? "")
            ])
        }
        if let claimID {
            let exitCode = Self.exitCode(of: output)
            try? await operations?.finish(claimID, outcome: exitCode == 0 ? .done : .failed)
        }

        // macOS tools treat bytes as multibyte characters in a UTF-8 locale and bail out
        // with "illegal byte sequence" on binary-ish input. One targeted retry with the
        // C locale is enough and does not change how normal commands read UTF-8.
        if output.contains("illegal byte sequence") {
            output = (try? await Task.detached(priority: .userInitiated) {
                try Self.runSync("export LC_ALL=C\n" + command, cwd: workspace, timeout: timeout, cancellation: cancellation)
            }.value) ?? output
        }

        // 2 000 characters by default. The old 30 000 reply was silently cut later by
        // the run budget, so the model lost it entirely; a small, announced window is
        // honest and keeps the run alive. `full` is the deliberate opt-in.
        // 8 000 is the ceiling even for `full`: a 30 000-character command log stays in
        // the history until the task ends and is exactly what the pruner has to clean up.
        // Narrow the command instead (head/tail/grep).
        let full = Self.bool(args, "full") ?? false
        let cap = full ? 8_000 : min(max(Self.int(args, "max_chars") ?? 2_000, 200), 8_000)
        guard output.count > cap else {
            return .ok(output.isEmpty ? "(команда выполнена, вывода нет)" : output)
        }
        let shown = String(output.prefix(cap))
        return .ok(shown + "\n[обрезано: показано \(cap) из \(output.count) символов; "
            + (full
               ? "предел 8 000 — сузь команду (head/tail/grep)"
               : "больше — full: true, но не больше 8 000") + "]")
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

        let pid = try ShellSpawn.spawn(
            command: command,
            cwd: cwd,
            stdoutPath: outURL.path,
            stderrPath: errURL.path,
            append: false
        )

        let done = DispatchSemaphore(value: 0)
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { done.signal() }
        source.resume()
        defer { source.cancel() }

        cancellation?.attach(pid: pid)
        // Cancellation signals the same semaphore the exit event does, so the wait is
        // event-driven. Polling every 50 ms woke the thread 20 times a second for the
        // whole life of every command and made an idle app sample as 100% CPU (R17).
        cancellation?.setOnCancel { done.signal() }
        defer { cancellation?.setOnCancel(nil) }

        let deadline = Date().addingTimeInterval(timeout)
        var stopped: StopReason?
        let remaining = max(deadline.timeIntervalSinceNow, 0.001)
        if done.wait(timeout: .now() + remaining) == .timedOut {
            stopped = .timedOut
        } else if cancellation?.isCancelled == true {
            // Woken by the cancellation handler or by the kill it triggered; either
            // way the user asked to stop and the child must not be waited on.
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

    static func exitCode(of output: String) -> Int {
        guard output.hasPrefix("exit ") else { return 1 }
        return Int(output.dropFirst(5).prefix { $0.isNumber }) ?? 1
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
        // A byte-limited read can land in the middle of a UTF-8 sequence; the decoder
        // turns the tail into U+FFFD. Dropping it is cleaner than showing "�".
        while text.hasSuffix("\u{FFFD}") { text.removeLast() }
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
    private var onCancel: (@Sendable () -> Void)?

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

    /// Called by `runSync` to let cancellation wake its semaphore instead of being
    /// polled for. Fires immediately when the run was already cancelled.
    func setOnCancel(_ handler: (@Sendable () -> Void)?) {
        lock.lock()
        let alreadyCancelled = cancelled
        onCancel = handler
        lock.unlock()
        if alreadyCancelled { handler?() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let target = pid
        let handler = onCancel
        lock.unlock()
        handler?()
        if target > 0 { kill(-target, SIGKILL) }
    }
}
