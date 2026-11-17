import Foundation

extension ToolRegistry {
    /// R23: Shortcuts is the textual layer Siri actions run on. `list` gives the model
    /// names to route by; `run` passes a file as input because that is what the CLI
    /// takes; `view` is for debugging. Descriptions are not available from the CLI.
    func shortcutTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "list"
        switch action {
        case "list":
            return await runTool("/usr/bin/shortcuts list", empty: "Шорткатов нет.")
        case "view":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return .fail("name обязателен")
            }
            return await runTool("/usr/bin/shortcuts view \(Self.shellQuote(name))", empty: "")
        case "run":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return .fail("name обязателен")
            }
            var command = "/usr/bin/shortcuts run \(Self.shellQuote(name))"
            var inputURL: URL?
            if let input = args["input"] as? String, !input.isEmpty {
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("shortcut-in-\(UUID().uuidString).txt")
                try? Data(input.utf8).write(to: url)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                inputURL = url
                command += " --input-path \(Self.shellQuote(url.path))"
            }
            defer { if let inputURL { try? FileManager.default.removeItem(at: inputURL) } }
            return await runTool(command, empty: "Шорткат выполнен, вывода нет.")
        default:
            return .fail("action: list | run | view")
        }
    }

    /// R20.3 / R23 second channel: a direct AppleScript or JXA call to an application.
    /// `System Events` is refused by TCC on this machine, so UI automation stays in
    /// R18; this is for dictionary-based apps (Safari, Finder, Mail).
    func appScriptTool(_ args: [String: Any]) async -> ToolResult {
        guard let source = args["source"] as? String, !source.isEmpty else {
            return .fail("source обязателен")
        }
        let language = (args["language"] as? String)?.lowercased() ?? "applescript"
        let command: String
        switch language {
        case "applescript":
            command = "/usr/bin/osascript -e \(Self.shellQuote(source))"
        case "jxa", "javascript":
            command = "/usr/bin/osascript -l JavaScript -e \(Self.shellQuote(source))"
        default:
            return .fail("language: applescript | jxa")
        }
        return await runTool(command, empty: "(скрипт выполнен, вывода нет)")
    }

    private func runTool(_ command: String, empty: String) async -> ToolResult {
        do {
            let output = try await Self.runDetached(command, cwd: workspace, timeout: 60)
            let (status, body) = Self.splitExit(output)
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if status != 0 {
                return .fail("exit \(status)\n" + (text.isEmpty ? "(без вывода)" : text))
            }
            return .ok(text.isEmpty ? empty : text)
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}
