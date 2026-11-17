import Foundation

/// R19.7: one JSON line per GUI action in `logs/ui_actions.log`. The agent must be able
/// to prove what it pressed; the person must be able to read it without decoding.
final class UIActionJournalInterceptor: ToolInterceptor, @unchecked Sendable {
    let name = "ui_journal"
    private let fileURL: URL
    private let lock = NSLock()

    init(directory: URL = AppPaths.logsDirectory) {
        fileURL = directory.appendingPathComponent("ui_actions.log")
    }

    /// Synchronous on purpose: a lock must not be held across an await.
    private func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        try? AppPaths.ensureDirectory(fileURL.deletingLastPathComponent())
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(
                atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600]
            )
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data((line + "\n").utf8))
        }
    }

    func afterResult(
        _ call: ToolCall, result: ToolResult, context: ToolCallContext
    ) async -> ToolResult {
        guard ["ui", "mouse", "keyboard", "clipboard"].contains(call.name) else { return result }
        let entry: [String: String] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "tool": call.name,
            "args": String(call.arguments.prefix(400)),
            "result": result.isError ? "error" : "ok",
            "head": String(result.output.prefix(200))
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return result }
        append(line)
        return result
    }
}
