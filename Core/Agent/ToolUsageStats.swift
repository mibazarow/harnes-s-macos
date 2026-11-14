import Foundation

/// What the transcript says about tool usage.
///
/// The complaint "it calls tools ten times where two would do" is only fixable with
/// numbers: how many steps a run takes, which tools dominate, and how long the same
/// tool is hammered in a row. This analyzer works on stored messages, so no schema
/// change and no second source of truth is needed.
struct ToolUsageStats: Sendable, Equatable {
    var steps: Int = 0
    var toolCalls: Int = 0
    var perTool: [String: Int] = [:]
    var longestRun: Int = 0
    var longestRunTool: String?

    var isEmpty: Bool { toolCalls == 0 }

    /// Average calls per step, the headline number for "too many tool calls".
    var callsPerStep: Double {
        steps == 0 ? 0 : Double(toolCalls) / Double(steps)
    }

    static func analyze(_ messages: [ChatMessage]) -> ToolUsageStats {
        var stats = ToolUsageStats()
        var currentRun = 0
        var currentTool: String?

        for message in messages where message.role == .assistant {
            // Exchanges and traces describe the same calls; exchanges carry the exact
            // arguments and exist for every completed call, so they win when present.
            let names: [String] = message.exchanges.isEmpty
                ? message.tools.map(\.name)
                : message.exchanges.map(\.name)
            guard !names.isEmpty else { continue }
            stats.steps += 1

            for name in names {
                stats.toolCalls += 1
                stats.perTool[name, default: 0] += 1

                if name == currentTool {
                    currentRun += 1
                } else {
                    currentTool = name
                    currentRun = 1
                }
                if currentRun > stats.longestRun {
                    stats.longestRun = currentRun
                    stats.longestRunTool = name
                }
            }
        }

        return stats
    }

    var summary: String {
        guard !isEmpty else { return "Вызовов инструментов пока не было." }
        let top = perTool.sorted { $0.value > $1.value }
            .prefix(6)
            .map { "  \($0.key) — \($0.value)" }
            .joined(separator: "\n")
        var lines = [
            "Шагов с инструментами: \(steps)",
            "Вызовов: \(toolCalls) (\(String(format: "%.1f", callsPerStep)) на шаг)",
            "Топ инструментов:",
            top
        ]
        if longestRun > 2, let tool = longestRunTool {
            lines.append("Самая длинная серия одного инструмента: \(tool) × \(longestRun)")
        }
        return lines.joined(separator: "\n")
    }
}
