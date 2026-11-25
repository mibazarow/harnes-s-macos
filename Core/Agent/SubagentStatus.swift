import Foundation

/// S2: the status text, as a pure function of the child snapshot and the clock.
///
/// Kept out of the registry so the wording can be tested without an actor, and so the
/// header, the tool and any future surface render the same facts.
enum SubagentStatus {
    /// `1:47` under an hour, `1:02:03` above it.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    private static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) с назад" }
        if seconds < 3_600 { return "\(seconds / 60) мин назад" }
        return duration(TimeInterval(seconds)) + " назад"
    }

    static func detail(_ child: SubagentRegistry.Child, now: Date = Date()) -> String {
        if let finishedAt = child.finishedAt {
            var line = "\(child.id) · завершён \(duration(finishedAt.timeIntervalSince(child.startedAt)))"
            if child.calls > 0 { line += " · \(child.calls) вызовов" }
            line += " · отчёт в транскрипте"
            var lines = [line, "задача: \(child.title)"]
            if let outcome = child.outcome, !outcome.isEmpty {
                lines.append("итог: \(outcome)")
            }
            return lines.joined(separator: "\n")
        }

        var line = "\(child.id) · работает \(duration(now.timeIntervalSince(child.startedAt)))"
        line += " · шаг \(child.step)/\(child.maxSteps)"
        if child.calls > 0 { line += " · \(child.calls) вызовов" }
        var lines = [line, "задача: \(child.title)"]
        if let tool = child.lastTool {
            let when = child.lastToolAt.map { " (\(ago($0, now: now)))" } ?? ""
            lines.append("последний инструмент: \(tool)\(when)")
        }
        if child.cancelled {
            lines.append("остановлен: \(child.reason ?? "без причины")")
        }
        return lines.joined(separator: "\n")
    }

    static func list(_ children: [SubagentRegistry.Child], now: Date = Date()) -> String {
        guard !children.isEmpty else { return "Живых подагентов нет." }
        let body = children.map { detail($0, now: now) }.joined(separator: "\n\n")
        let live = children.filter { !$0.isFinished }.count
        let done = children.count - live
        return body + "\n\nВсего: \(children.count) (живых \(live), завершённых \(done))."
    }
}
