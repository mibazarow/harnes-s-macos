import Foundation

/// What a subagent produced.
///
/// A bare String could not distinguish "answered with an empty string" from "ran out of
/// steps while calling tools", and the tool reported both as a successful empty answer.
struct SubagentOutcome: Sendable {
    var text: String
    var error: String?
    var steps: Int = 0
    var calls: Int = 0
    /// The hard call budget stopped the run; the text is what it had at that point.
    var truncated: Bool = false

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

extension ToolRegistry {
// MARK: - Agent state
    func runSubagent(_ args: [String: Any]) async -> ToolResult {
        guard let subagent else { return .fail("Подагенты недоступны") }
        guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
            return .fail("prompt обязателен")
        }
        let readOnly = Self.bool(args, "read_only") ?? true

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

        let outcome = await subagent(context, readOnly)
        if outcome.isEmpty {
            // An empty answer is a failure, not a result. Name the likely cause so the
            // parent can retry with a narrower prompt instead of pretending it worked.
            let reason = outcome.error
                ?? "не вернул текст за \(outcome.steps) шагов (\(outcome.calls) вызовов инструментов)"
            return .fail("Подагент: \(reason). Уточни задачу или сузь paths.")
        }
        return .ok(String(outcome.text.prefix(20_000)))
    }

    func todoWrite(_ args: [String: Any]) -> ToolResult {
        guard let todos else { return .fail("План недоступен") }
        do {
            let outcome: TodoStore.Outcome
            if let updates = (args["update"] as? [[String: Any]]) ?? (args["updates"] as? [[String: Any]]) {
                outcome = try todos.update(updates)
            } else if let complete = args["complete"] as? [Any] {
                let indices = complete.compactMap { Coerce.int($0) }
                guard !indices.isEmpty else {
                    return .fail("complete: нужен массив номеров шагов, считая с единицы")
                }
                outcome = try todos.complete(indices: indices)
            } else {
                // `so far` list replacement. Empty items clears the plan.
                let payload: Any = args["items"] ?? args["todos"] ?? args["tasks"] ?? args
                outcome = try todos.set(json: payload)
            }

            if todos.items.isEmpty { return .ok("План очищен.") }

            var notes: [String] = []
            if !outcome.demoted.isEmpty {
                notes.append("Активным оставлен последний шаг; в pending переведены: "
                    + outcome.demoted.joined(separator: ", "))
            }
            if !outcome.doneWithoutEvidence.isEmpty {
                notes.append("Отмечены done без evidence: "
                    + outcome.doneWithoutEvidence.joined(separator: ", ")
                    + ". Для проверяемых шагов добавь evidence, что именно сделано.")
            }
            let suffix = notes.isEmpty ? "" : "\n\n" + notes.joined(separator: "\n")
            return .ok("План обновлён:\n" + todos.summary + suffix)
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    /// Called by the loop after a stretch of work. The threshold comes from the plan
    /// size (`TodoStore.nudgeThreshold`), so the number lives in one place.
    func todoNudge(callsSinceUpdate: Int) -> String? {
        guard let todos, callsSinceUpdate >= todos.nudgeThreshold else { return nil }
        let open = todos.openItems
        guard !open.isEmpty else { return nil }
        let active = todos.items.filter { $0.status == "active" }
        let current = active.first?.text ?? open[0].text
        var note = "[напоминание: \(callsSinceUpdate) вызовов без обновления плана"
        if active.count > 1 {
            note += "; активных шагов \(active.count) — оставь один"
        }
        note += "; открыт шаг «\(current)» — отметь прогресс через todowrite]"
        return note
    }

    func todoRead() -> ToolResult {
        guard let todos else { return .fail("План недоступен") }
        return .ok(todos.summary)
    }

    func git(_ args: [String]) async throws -> ToolResult {
        let command = "git " + args.joined(separator: " ")
        let result = Self.splitExit(try await Self.runDetached(command, cwd: workspace, timeout: 30))
        // A failing git command (not a repository, bad revision) is an error the model
        // has to see, not an empty successful answer.
        return result.status == 0
            ? .ok(result.body.isEmpty ? "(пусто)" : result.body)
            : .fail("git \(args.first ?? ""): \(result.body)")
    }

    func gitDiff(_ args: [String: Any]) async throws -> ToolResult {
        let staged = Self.bool(args, "staged") ?? false
        return try await git(staged ? ["diff", "--staged", "--stat", "-p"] : ["diff", "--stat", "-p"])
    }

    func gitLog(_ args: [String: Any]) async throws -> ToolResult {
        let limit = max(1, min(Self.int(args, "limit") ?? 10, 100))
        return try await git(["log", "--oneline", "-n", "\(limit)"])
    }

// MARK: - Scheduler
    func scheduleAdd(_ args: [String: Any]) throws -> ToolResult {
        guard let scheduler else { return .fail("Планировщик недоступен") }
        guard let title = args["title"] as? String, let prompt = args["prompt"] as? String else {
            return .fail("Нужны title и prompt")
        }
        let minutes = Self.int(args, "interval_minutes")
        let at = (args["at"] as? String).flatMap(Self.parseISO8601)
        guard minutes != nil || at != nil else {
            return .fail("Нужен interval_minutes (повтор) или at (ISO8601, одноразово)")
        }
        if minutes != nil, at != nil {
            return .fail("Выбери одно: interval_minutes или at")
        }

        let task = try scheduler.add(
            title: title, prompt: prompt, intervalMinutes: minutes ?? 0, firesAt: at
        )
        if let firesAt = task.firesAt {
            return .ok("Одноразовая задача #\(task.id) «\(task.title)» на \(firesAt).")
        }
        return .ok("Расписание #\(task.id) создано: «\(task.title)» каждые \(task.intervalMinutes) мин.")
    }

    /// Models send both `2026-11-15T15:00:00Z` and the same with fractional seconds.
    static func parseISO8601(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        if let date = plain.date(from: text) { return date }
        plain.formatOptions.insert(.withFractionalSeconds)
        return plain.date(from: text)
    }

    func scheduleList() throws -> ToolResult {
        guard let scheduler else { return .fail("Планировщик недоступен") }
        let tasks = try scheduler.list()
        guard !tasks.isEmpty else { return .ok("Расписаний нет.") }

        return .ok(tasks.map { task in
            let state = task.enabled ? "вкл" : "выкл"
            if let firesAt = task.firesAt {
                return "#\(task.id) «\(task.title)» — одноразово в \(firesAt), \(state)"
            }
            return "#\(task.id) «\(task.title)» — каждые \(task.intervalMinutes) мин, \(state), следующее: \(task.nextRunAt)"
        }.joined(separator: "\n"))
    }

    func scheduleRemove(_ args: [String: Any]) throws -> ToolResult {
        guard let scheduler else { return .fail("Планировщик недоступен") }
        guard let id = Self.int(args, "id").map(Int64.init) else {
            return .fail("Нужен id")
        }
        try scheduler.remove(id: id)
        return .ok("Расписание #\(id) удалено.")
    }
}
