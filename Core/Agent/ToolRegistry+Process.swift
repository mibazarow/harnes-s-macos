import Foundation

extension ToolRegistry {
    func processTool(_ args: [String: Any]) async -> ToolResult {
        guard let processes else { return .fail("Фоновые процессы недоступны.") }
        let action = (args["action"] as? String)?.lowercased() ?? ""

        switch action {
        case "run":
            guard let command = args["command"] as? String, !command.isEmpty else {
                return .fail("command обязателен для action=run")
            }
            let cwd = resolve(args["cwd"] as? String ?? ".")
            do {
                let started = try await processes.run(command: command, cwd: cwd)
                return .ok("Запущено: id=\(started.id) pid=\(started.pid)\n"
                    + "process logs id=\(started.id) — вывод; process wait id=\(started.id) — дождаться.")
            } catch {
                return .fail(error.localizedDescription)
            }

        case "list":
            let list = await processes.list()
            guard !list.isEmpty else { return .ok("Фоновых процессов нет.") }
            return .ok(list.map { info in
                let state = info.exitCode.map { "exit \($0)" } ?? "running"
                return "\(info.id) pid=\(info.pid) \(state) \(info.command.prefix(100))"
            }.joined(separator: "\n"))

        case "logs":
            guard let id = args["id"] as? String else { return .fail("id обязателен") }
            do {
                return .ok(try await processes.logs(
                    id: id,
                    lines: Self.int(args, "lines") ?? 50,
                    filter: args["filter"] as? String
                ))
            } catch { return .fail(error.localizedDescription) }

        case "stop":
            guard let id = args["id"] as? String else { return .fail("id обязателен") }
            do {
                try await processes.stop(id: id)
                return .ok("Остановлен \(id).")
            } catch { return .fail(error.localizedDescription) }

        case "wait":
            guard let id = args["id"] as? String else { return .fail("id обязателен") }
            let timeout = Double(min(max(Self.int(args, "timeout_ms") ?? 30_000, 1_000), 600_000)) / 1_000
            do {
                return .ok(try await processes.wait(id: id, timeout: timeout))
            } catch { return .fail(error.localizedDescription) }

        default:
            return .fail("action: run | list | logs | stop | wait")
        }
    }
}
