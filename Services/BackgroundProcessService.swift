import Darwin
import Foundation

/// Long-lived commands that outlive one tool call: dev servers, watchers, builds.
///
/// `bash` waits for the command to finish and kills its process group on timeout, so
/// anything that does not exit is unusable there. This keeps a small registry of
/// children in their own groups, writes their output to a log file, and lets the model
/// start, inspect, wait for and stop them (R20.0).
actor BackgroundProcessService {
    struct Info: Sendable {
        let id: String
        let pid: pid_t
        let command: String
        let started: Date
        let exitCode: Int32?
        var running: Bool { exitCode == nil }
    }

    private struct Entry {
        let id: String
        let pid: pid_t
        let command: String
        let started: Date
        let logURL: URL
        var exitCode: Int32?
    }

    static let limit = 8
    static let logByteCap = 512 * 1024

    private let directory: URL
    private var entries: [String: Entry] = [:]
    private var loaded = false

    init(directory: URL? = nil) {
        self.directory = directory
            ?? AppPaths.logsDirectory.appendingPathComponent("procs", isDirectory: true)
    }

    func run(command: String, cwd: URL) throws -> (id: String, pid: pid_t) {
        ensureLoaded()
        let alive = entries.values.filter { isAlive($0.pid) }
        guard alive.count < Self.limit else {
            throw NSError(domain: "Harness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Уже запущено \(alive.count) фоновых процессов (потолок \(Self.limit)). Останови лишние."
            ])
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = String(UUID().uuidString.prefix(6)).lowercased()
        let logURL = directory.appendingPathComponent("\(id).log")
        FileManager.default.createFile(
            atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
        )

        let pid = try ShellSpawn.spawn(
            command: command,
            cwd: cwd,
            stdoutPath: logURL.path,
            stderrPath: logURL.path,
            append: true
        )

        entries[id] = Entry(
            id: id, pid: pid, command: command, started: Date(),
            logURL: logURL, exitCode: nil
        )
        persist()

        // A `let` snapshot: capturing the mutable local in a detached closure is the
        // warning the compiler emitted, and the pid does not change after spawn.
        let childPID = pid
        DispatchQueue.global().async { [weak self] in
            var status: Int32 = 0
            waitpid(childPID, &status, 0)
            let code: Int32 = (status & 0x7F) == 0
                ? (status >> 8) & 0xFF
                : 128 + (status & 0x7F)
            Task { await self?.finish(id: id, code: code) }
        }
        return (id, pid)
    }

    func list() -> [Info] {
        ensureLoaded()
        return entries.values
            .map { entry in
                Info(
                    id: entry.id, pid: entry.pid, command: entry.command,
                    started: entry.started,
                    exitCode: entry.exitCode ?? (isAlive(entry.pid) ? nil : -1)
                )
            }
            .sorted { $0.started > $1.started }
    }

    func logs(id: String, lines: Int, filter: String?) throws -> String {
        ensureLoaded()
        guard let entry = entries[id] else {
            throw NSError(domain: "Harness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Нет процесса \(id)."
            ])
        }
        let text = try Self.tail(entry.logURL, bytes: Self.logByteCap)
        var rows = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let filter, !filter.isEmpty {
            rows = rows.filter { $0.localizedCaseInsensitiveContains(filter) }
        }
        let shown = rows.suffix(max(lines, 1))
        let state = entry.exitCode.map { "exit \($0)" } ?? "running"
        return "[\(id)] \(state), последние \(shown.count) строк\n" + shown.joined(separator: "\n")
    }

    func stop(id: String) async throws {
        ensureLoaded()
        guard let entry = entries[id] else {
            throw NSError(domain: "Harness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Нет процесса \(id)."
            ])
        }
        guard entry.exitCode == nil, isAlive(entry.pid) else { return }
        kill(-entry.pid, SIGTERM)
        try? await Task.sleep(for: .seconds(2))
        if isAlive(entry.pid) { kill(-entry.pid, SIGKILL) }
        entries[id]?.exitCode = entry.exitCode ?? -1
        persist()
    }

    /// Waits for the process, then returns its exit code and the log tail.
    func wait(
        id: String,
        timeout: TimeInterval,
        tailLines: Int = 20,
        cancel: AgentAbortSignal? = nil
    ) async throws -> String {
        ensureLoaded()
        guard let entry = entries[id] else {
            throw NSError(domain: "Harness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Нет процесса \(id)."
            ])
        }
        let deadline = Date().addingTimeInterval(timeout)
        while entries[id]?.exitCode == nil, Date() < deadline {
            // R32.3: `try?` used to swallow cancellation, so a stop waited out the whole
            // timeout. A stop is a stop: leave the loop and let the caller report it.
            if Task.isCancelled || cancel?.current != nil { throw CancellationError() }
            try? await Task.sleep(for: .milliseconds(100))
            if !isAlive(entry.pid), entries[id]?.exitCode == nil {
                entries[id]?.exitCode = -1
            }
        }
        guard let code = entries[id]?.exitCode else {
            throw NSError(domain: "Harness", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Процесс \(id) не завершился за \(Int(timeout)) с."
            ])
        }
        let text = try Self.tail(entry.logURL, bytes: Self.logByteCap)
        let rows = text.split(separator: "\n").suffix(tailLines).joined(separator: "\n")
        return "exit \(code)\n" + rows
    }

    // MARK: - Private

    private func finish(id: String, code: Int32) {
        entries[id]?.exitCode = code
        persist()
    }

    private func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0
    }

    private static func tail(_ url: URL, bytes: Int) throws -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: manifestURL),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return
        }
        for item in raw {
            guard let id = item["id"] as? String,
                  let pid = item["pid"] as? Int,
                  let command = item["command"] as? String,
                  let started = item["started"] as? Double else { continue }
            let logURL = directory.appendingPathComponent("\(id).log")
            entries[id] = Entry(
                id: id, pid: pid_t(pid), command: command,
                started: Date(timeIntervalSince1970: started), logURL: logURL,
                exitCode: isAlive(pid_t(pid)) ? nil : -1
            )
        }
    }

    private func persist() {
        let raw = entries.values.map { entry -> [String: Any] in
            [
                "id": entry.id,
                "pid": Int(entry.pid),
                "command": entry.command,
                "started": entry.started.timeIntervalSince1970,
                "exit": entry.exitCode.map(Int.init) ?? -999
            ]
        }
        if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted]) {
            try? data.write(to: manifestURL, options: [.atomic])
        }
    }
}
