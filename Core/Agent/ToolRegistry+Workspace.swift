import Foundation

extension ToolRegistry {
    /// R20.4: switching the folder the agent lives in. `set` is a dangerous handle, so it
    /// needs an explicit path and `confirm: true`; the read-only flag travels with the
    /// folder because it belongs to the turn, not to the root.
    func workspaceTool(_ args: [String: Any]) -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "get"
        switch action {
        case "get":
            return .ok(describe(workspace))
        case "list":
            let current = workspace.standardizedFileURL
            var lines = ["current: " + display(current)]
            let recent = WorkspaceBookmarks.recent().filter { $0 != current }
            if recent.isEmpty {
                lines.append("Недавних других папок нет.")
            } else {
                lines.append("Недавние:")
                lines += recent.map { url in
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    return "  " + display(url) + (exists ? "" : " (нет на диске)")
                }
            }
            return .ok(lines.joined(separator: "\n"))
        case "set":
            guard let raw = args["path"] as? String,
                  !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .fail("path обязателен: явный путь к папке проекта.")
            }
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("workspace set требует confirm: true — это меняет корень всех "
                    + "относительных путей, git и поиска. Никогда не делай это молча.")
            }
            if readOnly {
                return .fail("workspace set недоступен в режиме только-чтение.")
            }
            let url = resolve(raw).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return .fail("Папка не найдена: \(display(url)).")
            }
            if let refusal = Self.workspaceGuard(url) { return .fail(refusal) }
            if url == workspace.standardizedFileURL {
                return .ok("workspace уже здесь: \(display(url))")
            }
            let previous = workspace
            WorkspaceBookmarks.setCurrent(url)
            workspaceState.url = url
            return .ok("workspace: \(display(previous)) → \(display(url))\n"
                + "Относительные пути, git, поиск и индекс теперь считаются от нового корня. "
                + "Следующий запрос к модели соберёт системный промпт заново с инструкциями "
                + "этого проекта и сбросит кэш префикса. read_only=\(readOnly ? "on" : "off") "
                + "перенесён без изменений.")
        default:
            return .fail("action: get | set | list")
        }
    }

    private func describe(_ url: URL) -> String {
        var lines = ["path: " + display(url)]
        let exists = FileManager.default.fileExists(atPath: url.path)
        lines.append("exists: \(exists)")
        if exists {
            lines.append("git: " + (Self.isGitRepository(url) ? "yes" : "no"))
            let instructions = [".kilo", ".kilocode", "AGENTS.md", "CLAUDE.md"]
                .filter { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
            lines.append("instructions: " + (instructions.isEmpty ? "none" : instructions.joined(separator: ", ")))
        }
        lines.append("read_only: \(readOnly ? "on" : "off")")
        return lines.joined(separator: "\n")
    }

    /// A workspace is a project folder, not the whole machine. Writing to `/` or to a
    /// system root from a relative path is the failure mode this guard removes.
    static func workspaceGuard(_ url: URL) -> String? {
        let path = url.standardizedFileURL.path
        if path == "/" { return "Корень файловой системы не может быть workspace." }
        if path == NSHomeDirectory() {
            return "Домашняя папка целиком не может быть workspace: выбери проект внутри неё."
        }
        for root in forbiddenWriteRoots where path == root || path.hasPrefix(root + "/") {
            return "\(root) — системный каталог, workspace туда не переключается."
        }
        for directory in [AppPaths.databaseDirectory, AppPaths.versionsDirectory,
                          AppPaths.trashDirectory, AppPaths.logsDirectory] {
            let base = directory.standardizedFileURL.path
            if path == base || path.hasPrefix(base + "/") {
                return "Служебные данные приложения не могут быть workspace."
            }
        }
        return nil
    }

    static func isGitRepository(_ url: URL) -> Bool {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if FileManager.default.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return true
            }
            current = current.deletingLastPathComponent()
        }
        return false
    }
}
