import Foundation
import ServiceManagement

extension ToolRegistry {
    /// R25.6: launch at login, this user's agents, Time Machine. The user's rule is
    /// explicit: no automatic backup agents are created — the tool reads and starts a
    /// backup by hand, and never resurrects a removed schedule.
    func launchdTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "status"
        switch action {
        case "login_item":
            let service = SMAppService.mainApp
            if let on = Self.bool(args, "value") {
                do {
                    if on {
                        try await service.register()
                    } else {
                        try await service.unregister()
                    }
                } catch {
                    return .fail("SMAppService.mainApp: \(error.localizedDescription). "
                        + "Статус: \(LaunchdParser.describe(service.status)).")
                }
                return .ok("Автозапуск при входе: "
                    + "\(on ? "включён" : "выключен") (\(LaunchdParser.describe(service.status))).")
            }
            return .ok("Автозапуск при входе: \(LaunchdParser.describe(service.status)). "
                + "Включить: login_item value=true.")

        case "agents":
            let uid = getuid()
            guard let output = try? Self.runSync(
                "launchctl print gui/\(uid)", cwd: workspace, timeout: 20
            ) else {
                return .fail("launchctl print gui/\(uid) не выполнился.")
            }
            let (status, body) = Self.splitExit(output)
            guard status == 0 else {
                return .fail("launchctl: " + String(body.prefix(400)))
            }
            let agents = LaunchdParser.parseAgents(body)
            guard !agents.isEmpty else {
                return .ok("Агентов в gui/\(uid) не найдено (или формат launchctl изменился).")
            }
            let filter = (args["filter"] as? String)?.lowercased()
            let shown = filter.map { needle in
                agents.filter { $0.label.lowercased().contains(needle) }
            } ?? agents
            let limit = min(max(Self.int(args, "limit") ?? 60, 1), 500)
            let lines = shown.prefix(limit).map { agent -> String in
                var line = agent.label
                if let pid = agent.pid { line += " pid=\(pid)" }
                line += " state=\(agent.state)"
                return line
            }
            return .ok("\(shown.count) агентов:\n" + lines.joined(separator: "\n"))

        case "tm_status":
            guard let output = try? Self.runSync("tmutil status", cwd: workspace, timeout: 20) else {
                return .fail("tmutil status не выполнился.")
            }
            let (status, body) = Self.splitExit(output)
            guard status == 0, let parsed = TimeMachineStatus.parse(body) else {
                return .fail("tmutil status: " + String(body.prefix(400)))
            }
            return .ok(parsed.summary)

        case "tm_start":
            guard let output = try? Self.runSync("tmutil startbackup", cwd: workspace, timeout: 30) else {
                return .fail("tmutil startbackup не выполнился.")
            }
            let (status, body) = Self.splitExit(output)
            guard status == 0 else {
                return .fail("tmutil startbackup: exit \(status) " + String(body.prefix(400)))
            }
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return .ok("Бэкап запущен вручную." + (text.isEmpty ? "" : "\n" + text))

        case "tm_list":
            guard let output = try? Self.runSync("tmutil listbackups", cwd: workspace, timeout: 30) else {
                return .fail("tmutil listbackups не выполнился.")
            }
            let (status, body) = Self.splitExit(output)
            guard status == 0 else {
                return .fail("tmutil listbackups: " + String(body.prefix(400)))
            }
            let lines = body.split(separator: "\n").map(String.init)
            guard !lines.isEmpty else { return .ok("Бэкапов нет.") }
            let limit = min(max(Self.int(args, "limit") ?? 20, 1), 200)
            return .ok("Бэкапы (последние \(min(limit, lines.count))):\n"
                + lines.suffix(limit).joined(separator: "\n"))

        case "tm_exclusions":
            guard let raw = args["path"] as? String else { return .fail("path обязателен") }
            let url = resolve(raw)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .fail("Путь не найден: \(display(url))")
            }
            let mode = (args["value"] as? String)?.lowercased() ?? "check"
            let command: String
            switch mode {
            case "add": command = "tmutil addexclusion \(Self.shellQuote(url.path))"
            case "remove": command = "tmutil removeexclusion \(Self.shellQuote(url.path))"
            case "check": command = "tmutil isexcluded \(Self.shellQuote(url.path))"
            default: return .fail("value: add | remove | check")
            }
            guard let output = try? Self.runSync(command, cwd: workspace, timeout: 20) else {
                return .fail("tmutil не выполнился.")
            }
            let (status, body) = Self.splitExit(output)
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return status == 0 ? .ok(text) : .fail("exit \(status): " + String(text.prefix(400)))

        default:
            return .fail("action: login_item | agents | tm_status | tm_start | tm_list | tm_exclusions")
        }
    }
}
