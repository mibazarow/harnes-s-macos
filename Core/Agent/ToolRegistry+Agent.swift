import Foundation

extension ToolRegistry {
// MARK: - Agent state
    func runSubagent(_ args: [String: Any]) async -> ToolResult {
        guard let subagent else { return .fail("Подагенты недоступны") }
        guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
            return .fail("prompt обязателен")
        }
        let readOnly = (args["read_only"] as? Bool) ?? true

        // Paths the caller already found are passed along verbatim. Without this the
        // subagent starts from zero and re-searches the whole workspace.
        var context = prompt
        if let paths = args["paths"] as? [String], !paths.isEmpty {
            var blocks: [String] = []
            for path in paths.prefix(12) {
                let url = resolve(path)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                    blocks.append("--- \(path): не найдено")
                    continue
                }
                if isDirectory.boolValue {
                    blocks.append("--- \(path)/ (папка)\n" + Self.renderTree(root: url, depth: 3) { self.display($0) })
                } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let clipped = text.count > 20_000 ? String(text.prefix(20_000)) + "\n…" : text
                    blocks.append("--- \(path)\n\(clipped)")
                } else {
                    blocks.append("--- \(path): бинарный или нечитаемый файл")
                }
            }
            context += "\n\n## Уже найденные файлы (не искать заново)\n" + blocks.joined(separator: "\n\n")
        }

        let answer = await subagent(context, readOnly)
        return .ok(answer.isEmpty ? "(подагент ничего не вернул)" : String(answer.prefix(20_000)))
    }

    func todoWrite(_ args: [String: Any]) -> ToolResult {
        guard let todos else { return .fail("План недоступен") }

        let payload: Any = args["items"] ?? args["todos"] ?? args["tasks"] ?? args
        todos.set(json: payload)

        guard !todos.items.isEmpty else {
            return .fail("План не принят: у элементов нет поля text. Пример: \"items\": [{\"text\": \"шаг\", \"status\": \"pending\"}]")
        }
        return .ok("План обновлён:\n" + todos.summary)
    }

    func todoRead() -> ToolResult {
        guard let todos else { return .fail("План недоступен") }
        return .ok(todos.summary)
    }

    func git(_ args: [String]) throws -> ToolResult {
        let command = "git " + args.joined(separator: " ")
        let output = try Self.runSync(command, cwd: workspace, timeout: 30)
        return .ok(output)
    }

    func gitDiff(_ args: [String: Any]) throws -> ToolResult {
        let staged = (args["staged"] as? Bool) ?? false
        return try git(staged ? ["diff", "--staged", "--stat", "-p"] : ["diff", "--stat", "-p"])
    }

    func gitLog(_ args: [String: Any]) throws -> ToolResult {
        let limit = max(1, min((args["limit"] as? Int) ?? 10, 100))
        return try git(["log", "--oneline", "-n", "\(limit)"])
    }

// MARK: - Scheduler
    func scheduleAdd(_ args: [String: Any]) throws -> ToolResult {
        guard let scheduler else { return .fail("Планировщик недоступен") }
        guard let title = args["title"] as? String,
              let prompt = args["prompt"] as? String,
              let minutes = (args["interval_minutes"] as? Int) ?? (args["interval_minutes"] as? Double).map(Int.init) else {
            return .fail("Нужны title, prompt и interval_minutes")
        }

        let task = try scheduler.add(title: title, prompt: prompt, intervalMinutes: minutes)
        return .ok("Расписание #\(task.id) создано: «\(task.title)» каждые \(task.intervalMinutes) мин.")
    }

    func scheduleList() throws -> ToolResult {
        guard let scheduler else { return .fail("Планировщик недоступен") }
        let tasks = try scheduler.list()
        guard !tasks.isEmpty else { return .ok("Расписаний нет.") }

        return .ok(tasks.map { task in
            let state = task.enabled ? "вкл" : "выкл"
            return "#\(task.id) «\(task.title)» — каждые \(task.intervalMinutes) мин, \(state), следующее: \(task.nextRunAt)"
        }.joined(separator: "\n"))
    }

    func scheduleRemove(_ args: [String: Any]) throws -> ToolResult {
        guard let scheduler else { return .fail("Планировщик недоступен") }
        guard let id = (args["id"] as? Int).map(Int64.init) ?? (args["id"] as? Double).map({ Int64($0) }) else {
            return .fail("Нужен id")
        }
        try scheduler.remove(id: id)
        return .ok("Расписание #\(id) удалено.")
    }
}
