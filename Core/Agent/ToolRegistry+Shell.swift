import Foundation

extension ToolRegistry {
// MARK: - Shell and process
    func runShell(_ args: [String: Any]) async throws -> ToolResult {
        guard let command = args["command"] as? String else { return .fail("command обязателен") }
        let timeout = TimeInterval(min(max((args["timeout_ms"] as? Int) ?? 60_000, 1_000), 600_000)) / 1_000
        let output = try await Task.detached(priority: .userInitiated) {
            try Self.runSync(command, cwd: self.workspace, timeout: timeout)
        }.value
        return .ok(output.isEmpty ? "(команда выполнена, вывода нет)" : String(output.prefix(30_000)))
    }

    static func runSync(_ command: String, cwd: URL, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = cwd

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

        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        process.standardOutput = outHandle
        process.standardError = errHandle

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            throw NSError(domain: "Harness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Команда превысила таймаут \(Int(timeout)) с и была остановлена."
            ])
        }

        try? outHandle.close()
        try? errHandle.close()

        let out = String(data: (try? Data(contentsOf: outURL)) ?? Data(), encoding: .utf8) ?? ""
        let err = String(data: (try? Data(contentsOf: errURL)) ?? Data(), encoding: .utf8) ?? ""
        let merged = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
        return "exit \(process.terminationStatus)\n" + merged
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
