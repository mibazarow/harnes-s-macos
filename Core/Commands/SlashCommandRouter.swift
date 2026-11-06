import Foundation

struct SlashCommandResult: Sendable {
    let text: String
    let isError: Bool

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

struct SlashCommandRouter: Sendable {
    let skills: SkillsService
    let mcp: MCPService
    let secrets: SecretsService
    let memory: MemoryService

    func handle(_ input: String) async -> SlashCommandResult {
        let tokens = Self.tokenize(input)
        guard let command = tokens.first?.lowercased() else {
            return SlashCommandResult(Self.helpText)
        }

        switch command {
        case "/help", "/?":
            return SlashCommandResult(Self.helpText)
        case "/skills", "/skill":
            return await handleSkills(Array(tokens.dropFirst()))
        case "/mcp":
            return await handleMCP(Array(tokens.dropFirst()))
        case "/secret", "/secrets":
            return await handleSecrets(Array(tokens.dropFirst()))
        case "/remember", "/memory":
            return await handleMemory(command: command, Array(tokens.dropFirst()))
        case "/search":
            return await searchMemory(Array(tokens.dropFirst()).joined(separator: " "))
        default:
            return SlashCommandResult(
                "Неизвестная команда `\(command)`. Список — `/help`.",
                isError: true
            )
        }
    }

    private func handleSkills(_ arguments: [String]) async -> SlashCommandResult {
        guard let subcommand = arguments.first?.lowercased() else {
            return await listSkills()
        }

        switch subcommand {
        case "list":
            return await listSkills()
        case "install":
            let source = arguments.dropFirst().first { !$0.hasPrefix("--") }
            guard let source else {
                return SlashCommandResult("Нужен путь или URL: `/skill install <путь|url>`", isError: true)
            }
            let force = arguments.contains("--force")
            do {
                let record = try await skills.install(from: source, force: force)
                return SlashCommandResult("""
                **Скилл установлен.**

                - имя: `\(record.name)`
                - scope: \(record.scope.rawValue)
                - состояние: включён
                - путь: `\(Self.display(record.directory))`
                """)
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        case "remove", "delete":
            guard let name = arguments.dropFirst().first else {
                return SlashCommandResult("Нужно имя: `/skill remove <имя>`", isError: true)
            }
            do {
                try await skills.remove(name: name)
                return SlashCommandResult("Скилл `\(name)` удалён.")
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        case "enable", "disable":
            guard let name = arguments.dropFirst().first else {
                return SlashCommandResult("Нужно имя: `/skill \(subcommand) <имя>`", isError: true)
            }
            do {
                try await skills.setEnabled(name: name, enabled: subcommand == "enable")
                return SlashCommandResult("Скилл `\(name)` \(subcommand == "enable" ? "включён" : "выключен").")
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        default:
            return SlashCommandResult("Неизвестное действие `\(subcommand)`. `/skill list|install|remove|enable|disable`", isError: true)
        }
    }

    private func listSkills() async -> SlashCommandResult {
        let records = await skills.list()
        guard !records.isEmpty else {
            return SlashCommandResult("Скиллов нет.")
        }

        var lines = ["**Скиллы** — \(records.count)"]
        for record in records {
            let state = record.enabled ? "вкл" : "выкл"
            let summary = record.summary.isEmpty ? "" : " · \(Self.truncate(record.summary, to: 90))"
            lines.append("- `\(record.name)` · \(record.scope.rawValue) · \(state)\(summary)")
        }
        return SlashCommandResult(lines.joined(separator: "\n"))
    }

    private func handleMCP(_ arguments: [String]) async -> SlashCommandResult {
        guard let subcommand = arguments.first?.lowercased() else {
            return await listMCP()
        }

        switch subcommand {
        case "list":
            return await listMCP()
        case "add":
            return await addMCP(Array(arguments.dropFirst()))
        case "remove", "delete":
            guard let name = arguments.dropFirst().first else {
                return SlashCommandResult("Нужно имя: `/mcp remove <имя>`", isError: true)
            }
            do {
                try await mcp.remove(name: name)
                return SlashCommandResult("MCP-сервер `\(name)` удалён.")
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        case "enable", "disable":
            guard let name = arguments.dropFirst().first else {
                return SlashCommandResult("Нужно имя: `/mcp \(subcommand) <имя>`", isError: true)
            }
            do {
                try await mcp.setEnabled(name: name, enabled: subcommand == "enable")
                return SlashCommandResult("MCP-сервер `\(name)` \(subcommand == "enable" ? "включён" : "выключен").")
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        default:
            return SlashCommandResult("Неизвестное действие `\(subcommand)`. `/mcp list|add|remove|enable|disable`", isError: true)
        }
    }

    private func listMCP() async -> SlashCommandResult {
        do {
            let servers = try await mcp.list()
            guard !servers.isEmpty else {
                return SlashCommandResult("MCP-серверов нет.")
            }

            var lines = ["**MCP-серверы** — \(servers.count)"]
            for server in servers {
                let state = server.enabled ? "вкл" : "выкл"
                lines.append("- `\(server.name)` · \(server.transport.rawValue) · \(server.exposure) · \(state) · `\(Self.truncate(server.summary, to: 80))`")
            }
            return SlashCommandResult(lines.joined(separator: "\n"))
        } catch {
            return SlashCommandResult("Не удалось прочитать `mcp.json`: \(error.localizedDescription)", isError: true)
        }
    }

    private func addMCP(_ rawArguments: [String]) async -> SlashCommandResult {
        var positional: [String] = []
        var url: String?
        var transport: MCPTransport = .stdio
        var force = false

        var index = 0
        while index < rawArguments.count {
            let argument = rawArguments[index]
            switch argument {
            case "--url":
                index += 1
                guard index < rawArguments.count else {
                    return SlashCommandResult("После `--url` нужен адрес.", isError: true)
                }
                url = rawArguments[index]
            case "--sse":
                transport = .sse
            case "--http":
                transport = .http
            case "--force":
                force = true
            default:
                positional.append(argument)
            }
            index += 1
        }

        guard let name = positional.first else {
            return SlashCommandResult(
                "Нужно имя и команда/URL: `/mcp add <имя> <команда…>` или `/mcp add <имя> --url <адрес>`",
                isError: true
            )
        }

        let commandParts = Array(positional.dropFirst())
        if url != nil && !commandParts.isEmpty {
            return SlashCommandResult("Нельзя одновременно указать команду и `--url`.", isError: true)
        }

        let server: MCPServerConfig
        if let url {
            guard let parsed = URL(string: url), parsed.scheme != nil else {
                return SlashCommandResult("Некорректный URL: `\(url)`", isError: true)
            }
            if transport == .stdio {
                transport = .http
            }
            server = MCPServerConfig(name: name, transport: transport, url: url)
        } else {
            guard let command = commandParts.first else {
                return SlashCommandResult("Нужна команда запуска для stdio-сервера.", isError: true)
            }
            server = MCPServerConfig(
                name: name,
                transport: .stdio,
                command: command,
                args: Array(commandParts.dropFirst())
            )
        }

        do {
            try await mcp.add(server, force: force)
        } catch {
            return SlashCommandResult(error.localizedDescription, isError: true)
        }

        return SlashCommandResult("""
        **MCP-сервер сохранён.**

        - имя: `\(server.name)`
        - транспорт: \(server.transport.rawValue)
        - exposure: \(server.exposure)
        - состояние: включён
        - запуск: `\(Self.truncate(server.summary, to: 100))`

        Конфиг: `\(Self.display(AppPaths.mcpConfigURL))`
        Клиент MCP ещё не подключён: сервер начнёт работу вместе с MCP-слоем.
        """)
    }

    private func handleSecrets(_ arguments: [String]) async -> SlashCommandResult {
        guard let subcommand = arguments.first?.lowercased() else {
            return await listSecrets()
        }

        switch subcommand {
        case "list":
            return await listSecrets()
        case "save", "add", "set":
            guard arguments.count >= 3 else {
                return SlashCommandResult("Нужно: `/secret save <алиас> <значение>`", isError: true)
            }
            let alias = arguments[1]
            let value = arguments.dropFirst(2).joined(separator: " ")
            do {
                let item = try await secrets.save(alias: alias, value: value)
                return SlashCommandResult("""
                **Секрет сохранён.**

                - алиас: `\(item.alias)`
                - база: `\(Self.display(AppPaths.databaseURL))`
                """)
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        case "get", "show":
            guard let alias = arguments.dropFirst().first else {
                return SlashCommandResult("Нужно: `/secret get <алиас>`", isError: true)
            }
            do {
                guard let item = try await secrets.get(alias: alias) else {
                    return SlashCommandResult("Секрет `\(alias)` не найден.", isError: true)
                }
                var lines = ["**`\(item.alias)`**", "", "`\(item.value)`"]
                if let note = item.note, !note.isEmpty {
                    lines.append("")
                    lines.append(note)
                }
                return SlashCommandResult(lines.joined(separator: "\n"))
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        case "remove", "delete", "forget":
            guard let alias = arguments.dropFirst().first else {
                return SlashCommandResult("Нужно: `/secret remove <алиас>`", isError: true)
            }
            do {
                try await secrets.remove(alias: alias)
                return SlashCommandResult("Секрет `\(alias)` удалён.")
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        case "search":
            let query = arguments.dropFirst().joined(separator: " ")
            guard !query.isEmpty else {
                return SlashCommandResult("Нужно: `/secret search <текст>`", isError: true)
            }
            do {
                let items = try await secrets.search(query)
                guard !items.isEmpty else {
                    return SlashCommandResult("Секретов по запросу «\(query)» нет.")
                }
                var lines = ["**Секреты** — \(items.count)"]
                for item in items {
                    let note = item.note.map { " · \(Self.truncate($0, to: 60))" } ?? ""
                    lines.append("- `\(item.alias)`\(note)")
                }
                return SlashCommandResult(lines.joined(separator: "\n"))
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        default:
            return SlashCommandResult("Неизвестное действие `\(subcommand)`. `/secret list|save|get|remove|search`", isError: true)
        }
    }

    private func listSecrets() async -> SlashCommandResult {
        do {
            let items = try await secrets.list()
            guard !items.isEmpty else {
                return SlashCommandResult("Секретов нет.")
            }
            var lines = ["**Секреты** — \(items.count)"]
            for item in items {
                let note = item.note.map { " · \(Self.truncate($0, to: 60))" } ?? ""
                lines.append("- `\(item.alias)`\(note) · значения скрыты")
            }
            return SlashCommandResult(lines.joined(separator: "\n"))
        } catch {
            return SlashCommandResult(error.localizedDescription, isError: true)
        }
    }

    private func handleMemory(command: String, _ arguments: [String]) async -> SlashCommandResult {
        if command == "/remember" || arguments.first?.lowercased() == "add" {
            let text = command == "/remember"
                ? arguments.joined(separator: " ")
                : arguments.dropFirst().joined(separator: " ")
            guard !text.isEmpty else {
                return SlashCommandResult("Нужно: `/remember <текст>`", isError: true)
            }
            do {
                let item = try await memory.add(text)
                return SlashCommandResult("Запомнил `#\(item.id)`: \(Self.truncate(item.content, to: 140))")
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        }

        guard let subcommand = arguments.first?.lowercased() else {
            return await listMemory()
        }

        switch subcommand {
        case "list":
            return await listMemory()
        case "search":
            return await searchMemory(arguments.dropFirst().joined(separator: " "))
        case "delete", "remove":
            guard let raw = arguments.dropFirst().first, let id = Int64(raw) else {
                return SlashCommandResult("Нужно: `/memory delete <id>`", isError: true)
            }
            do {
                try await memory.delete(id: id)
                return SlashCommandResult("Запись `#\(id)` удалена.")
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        case "forget":
            let query = arguments.dropFirst().joined(separator: " ")
            guard !query.isEmpty else {
                return SlashCommandResult("Нужно: `/memory forget <текст|id>`", isError: true)
            }
            do {
                let removed = try await memory.forget(query: query)
                guard !removed.isEmpty else {
                    return SlashCommandResult("По запросу «\(query)» ничего не найдено.")
                }
                return SlashCommandResult("Забыто:\n" + removed.map { "`#\($0.id)` \($0.snippet)" }.joined(separator: "\n"))
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        case "pin", "unpin":
            guard let raw = arguments.dropFirst().first, let id = Int64(raw) else {
                return SlashCommandResult("Нужно: `/memory \(subcommand) <id>`", isError: true)
            }
            do {
                guard let item = try await memory.item(id: id) else {
                    return SlashCommandResult("Запись `#\(id)` не найдена.", isError: true)
                }
                try await memory.setPinned(id: id, pinned: subcommand == "pin")
                return SlashCommandResult("`#\(id)` \(subcommand == "pin" ? "закреплена" : "раскреплена"): \(item.snippet)")
            } catch {
                return SlashCommandResult(error.localizedDescription, isError: true)
            }
        default:
            return SlashCommandResult("Неизвестное действие `\(subcommand)`. `/memory list|search|delete`", isError: true)
        }
    }

    private func listMemory() async -> SlashCommandResult {
        do {
            let items = try await memory.recent(limit: 30)
            guard !items.isEmpty else {
                return SlashCommandResult("Память пуста. `/remember <текст>` — добавить.")
            }
            var lines = ["**Память** — последние \(items.count)"]
            for item in items {
                let mark = item.pinned ? "📌 " : ""
                lines.append("- `#\(item.id)` · \(mark)\(item.scope)/\(item.kind) · \(item.snippet)")
            }
            return SlashCommandResult(lines.joined(separator: "\n"))
        } catch {
            return SlashCommandResult(error.localizedDescription, isError: true)
        }
    }

    private func searchMemory(_ query: String) async -> SlashCommandResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return SlashCommandResult("Нужно: `/search <запрос>`", isError: true)
        }

        do {
            let hits = try await memory.search(query)
            guard !hits.isEmpty else {
                return SlashCommandResult("По запросу «\(query)» ничего не найдено.")
            }
            var lines = ["**Поиск: «\(query)»** — \(hits.count)"]
            for (index, hit) in hits.enumerated() {
                lines.append("\(index + 1). `#\(hit.id)` · \(hit.kind) · \(hit.snippet)")
            }
            return SlashCommandResult(lines.joined(separator: "\n"))
        } catch {
            return SlashCommandResult(error.localizedDescription, isError: true)
        }
    }

    private static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for character in input {
            if character == "\"" {
                inQuotes.toggle()
            } else if character == " " && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit - 1)) + "…"
    }

    private static func display(_ url: URL) -> String {
        let home = NSHomeDirectory()
        guard url.path.hasPrefix(home) else { return url.path }
        return "~" + url.path.dropFirst(home.count)
    }

    private static let helpText = """
    **Команды**
    - `/skills` — список скиллов
    - `/skill install <путь|url>` — установить (`--force` для замены)
    - `/skill remove <имя>` — удалить пользовательский скилл
    - `/skill enable|disable <имя>` — включить или выключить
    - `/mcp` — список MCP-серверов
    - `/mcp add <имя> <команда…>` — stdio-сервер
    - `/mcp add <имя> --url <адрес> [--sse]` — http/sse-сервер
    - `/mcp remove|enable|disable <имя>`
    - `/remember <текст>` — запомнить и закрепить
    - `/memory` — последние записи памяти
    - `/memory search <запрос>` или `/search <запрос>` — поиск по памяти
    - `/memory forget <текст|id>` — забыть
    - `/memory pin|unpin <id>` — закрепить запись
    - `/secret save <алиас> <значение>` — сохранить пароль/секрет
    - `/secret get <алиас>` — показать
    - `/secret list` / `/secret search <текст>` / `/secret remove <алиас>`
    - `/clear` — очистить вид
    """
}