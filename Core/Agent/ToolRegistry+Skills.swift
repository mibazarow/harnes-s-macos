import Foundation

extension ToolRegistry {
// MARK: - Skills and MCP
    func skillList() async -> ToolResult {
        guard let skills else { return .fail("Скиллы недоступны") }
        let records = await skills.list()
        guard !records.isEmpty else { return .ok("Скиллов нет.") }
        return .ok(records.map { "\($0.name) [\($0.scope.rawValue), \($0.enabled ? "вкл" : "выкл")] — \($0.summary)" }.joined(separator: "\n"))
    }

    func skillRead(_ args: [String: Any]) async -> ToolResult {
        guard let skills else { return .fail("Скиллы недоступны") }
        guard let name = args["name"] as? String, !name.isEmpty else { return .fail("name обязателен") }
        do {
            return .ok(try await skills.read(name: name))
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    func skillInstall(_ args: [String: Any]) async -> ToolResult {
        guard let skills else { return .fail("Скиллы недоступны") }
        guard let source = args["source"] as? String else { return .fail("source обязателен") }
        do {
            let record = try await skills.install(from: source, force: (args["force"] as? Bool) ?? false)
            return .ok("Скилл установлен: \(record.name)")
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    func mcpTools(_ args: [String: Any]) async -> ToolResult {
        guard let mcpManager else { return .fail("MCP-клиент недоступен") }
        let server = args["server"] as? String
        let tool = args["tool"] as? String
        let all = await mcpManager.tools()
        let filtered = all.filter { server == nil || $0.server == server }
        guard !filtered.isEmpty else {
            return .ok(server.map { "У сервера \($0) нет инструментов." } ?? "Инструментов MCP нет.")
        }

        if let tool {
            guard let match = filtered.first(where: { $0.name == tool }) else {
                return .fail("Инструмент \(tool) не найден.")
            }
            return .ok(renderMCPTool(match))
        }

        if server != nil {
            return .ok(filtered.map { "- \($0.name): \(String($0.description.prefix(200)))" + $0.argsLabel }.joined(separator: "\n"))
        }

        var lines: [String] = []
        for (name, group) in Dictionary(grouping: filtered, by: \.server).sorted(by: { $0.key < $1.key }) {
            lines.append("## \(name)")
            lines.append(contentsOf: group.map { "- \($0.name): \(String($0.description.prefix(160)))" + $0.argsLabel })
        }
        return .ok(String(lines.joined(separator: "\n").prefix(20_000)))
    }

    func renderMCPTool(_ tool: MCPToolDescriptor) -> String {
        var text = "# \(tool.server) / \(tool.name)\n\(tool.description)\n"
        text += "Exposure: \(tool.exposure)" + tool.argsLabel + "\n\n"
        let plain = tool.inputSchema.mapValues { $0.value }
        if let data = try? JSONSerialization.data(withJSONObject: plain, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            text += json
        }
        return String(text.prefix(20_000))
    }

    func callMCP(_ call: ToolCall, args: [String: Any]) async -> ToolResult {
        guard let mcpManager else { return .fail("MCP-клиент недоступен") }
        let parts = call.name.split(separator: "__", maxSplits: 2)
        guard parts.count == 3 else { return .fail("Некорректное имя MCP-инструмента: \(call.name)") }

        let server = String(parts[1])
        let tool = String(parts[2])
        let json = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        do {
            let output = try await mcpManager.call(server: server, tool: tool, argumentsJSON: json)
            return .ok(output.isEmpty ? "(пустой ответ)" : String(output.prefix(30_000)))
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    func mcpList() async -> ToolResult {
        guard let mcp else { return .fail("MCP недоступен") }
        do {
            let servers = try await mcp.list()
            guard !servers.isEmpty else { return .ok("MCP-серверов нет.") }
            let live = await mcpManager?.sessionsSnapshot() ?? []
            let byName = Dictionary(uniqueKeysWithValues: live.map { ($0.name, $0) })

            return .ok(servers.map { server in
                let state = byName[server.name]
                let status = state.map { "\($0.running ? "запущен" : "остановлен"), \($0.tools) инстр." } ?? "не запускался"
                return "\(server.name) [\(server.transport.rawValue), \(server.enabled ? "вкл" : "выкл"), \(status)] — \(server.summary)"
            }.joined(separator: "\n"))
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}
