import Foundation

extension ToolRegistry {
    /// R30.6: the journal, readable and exportable. `list` groups by day so a long run
    /// reads as a timeline, not as a wall of rows.
    func activityTool(_ args: [String: Any]) async -> ToolResult {
        guard let actions else { return .fail("Журнал действий недоступен в этом контексте.") }
        let action = (args["action"] as? String)?.lowercased() ?? "list"

        switch action {
        case "list":
            let limit = min(max(Self.int(args, "limit") ?? 40, 1), 500)
            do {
                let entries = try await actions.list(limit: limit)
                guard !entries.isEmpty else { return .ok("Журнал пуст.") }
                var lines: [String] = []
                var day = ""
                for entry in entries.reversed() {
                    let current = String(entry.at.prefix(10))
                    if current != day {
                        day = current
                        lines.append("## \(day)")
                    }
                    var line = "#\(entry.id) \(entry.tool) \(entry.outcome)"
                    if entry.promptTokens > 0 || entry.completionTokens > 0 {
                        line += " tokens=\(entry.promptTokens)/\(entry.completionTokens)"
                    }
                    if entry.costUSD > 0 {
                        line += String(format: " cost=$%.4f", entry.costUSD)
                    }
                    line += " because=\(entry.becauseKind)"
                    if !entry.argsSummary.isEmpty { line += " args=\(entry.argsSummary)" }
                    lines.append(line)
                }
                return .ok(lines.joined(separator: "\n"))
            } catch {
                return .fail("Журнал не прочитан: \(error.localizedDescription)")
            }

        case "show":
            guard let id = Self.int(args, "id") else { return .fail("id обязателен") }
            do {
                guard let entry = try await actions.show(Int64(id)) else {
                    return .fail("Записи #\(id) нет.")
                }
                return .ok("""
                id: \(entry.id)
                at: \(entry.at)
                tool: \(entry.tool)
                outcome: \(entry.outcome)
                model: \(entry.model)
                tokens: \(entry.promptTokens)/\(entry.completionTokens)
                cost_usd: \(String(format: "%.6f", entry.costUSD))
                because: \(entry.becauseKind) «\(entry.becauseQuote)»
                args: \(entry.argsSummary)
                """)
            } catch {
                return .fail("Запись не прочитана: \(error.localizedDescription)")
            }

        case "export":
            let now = Date()
            let from = (args["from"] as? String).flatMap(CalendarDates.parse)
                ?? now.addingTimeInterval(-30 * 86_400)
            let to = (args["to"] as? String).flatMap(CalendarDates.parse) ?? now
            do {
                let url = try await actions.export(from: from, to: to)
                return .ok("CSV: \(url.path)")
            } catch {
                return .fail("Экспорт не удался: \(error.localizedDescription)")
            }

        case "prune":
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("activity prune требует confirm: true: строки старше "
                    + "\(ActionJournal.retentionDays) дней удаляются из базы.")
            }
            do {
                let removed = try await actions.prune()
                return .ok("Удалено строк: \(removed). CSV-архив делай до prune.")
            } catch {
                return .fail("Prune не выполнен: \(error.localizedDescription)")
            }

        default:
            return .fail("action: list | show | export | prune")
        }
    }
}
