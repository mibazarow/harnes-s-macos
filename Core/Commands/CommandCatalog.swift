import Foundation

/// One row of the composer's slash-command palette.
struct CommandSuggestion: Identifiable, Equatable, Sendable {
    /// What goes into the composer when the row is picked.
    let insert: String
    /// Left column: the command itself.
    let title: String
    /// Right column: what it does.
    let detail: String

    var id: String { insert }
}

/// Slash commands as data. The palette, the `/help` text and the router all read from
/// here, so a new command is added once instead of in three places.
enum CommandCatalog {
    struct Command: Sendable {
        let name: String
        let summary: String
        var arguments: String?
        var subcommands: [Command] = []

        /// A command takes a space after it when it expects arguments or opens a
        /// submenu; without that the palette would hide itself too early.
        var wantsTrailingSpace: Bool { arguments != nil || !subcommands.isEmpty }
    }

    static let all: [Command] = [
        Command(name: "/help", summary: "все команды"),
        Command(name: "/clear", summary: "очистить вид, база не трогается"),
        Command(name: "/skills", summary: "список скиллов"),
        Command(name: "/skill", summary: "управление скиллами", subcommands: [
            Command(name: "list", summary: "список установленных"),
            Command(name: "install", summary: "установить скилл", arguments: "<путь|url> [--force]"),
            Command(name: "remove", summary: "удалить пользовательский", arguments: "<имя>"),
            Command(name: "enable", summary: "включить", arguments: "<имя>"),
            Command(name: "disable", summary: "выключить", arguments: "<имя>")
        ]),
        Command(name: "/mcp", summary: "MCP-серверы", subcommands: [
            Command(name: "list", summary: "список серверов"),
            Command(name: "add", summary: "подключить сервер", arguments: "<имя> <команда…>"),
            Command(name: "remove", summary: "удалить сервер", arguments: "<имя>"),
            Command(name: "enable", summary: "включить", arguments: "<имя>"),
            Command(name: "disable", summary: "выключить", arguments: "<имя>")
        ]),
        Command(name: "/remember", summary: "запомнить и закрепить", arguments: "<текст>"),
        Command(name: "/memory", summary: "память", subcommands: [
            Command(name: "list", summary: "последние записи"),
            Command(name: "search", summary: "поиск", arguments: "<запрос>"),
            Command(name: "forget", summary: "забыть", arguments: "<текст|id>"),
            Command(name: "delete", summary: "удалить по id", arguments: "<id>"),
            Command(name: "pin", summary: "закрепить", arguments: "<id>"),
            Command(name: "unpin", summary: "раскрепить", arguments: "<id>")
        ]),
        Command(name: "/search", summary: "поиск по памяти", arguments: "<запрос>"),
        Command(name: "/secret", summary: "секреты", subcommands: [
            Command(name: "save", summary: "сохранить пароль", arguments: "<алиас> <значение>"),
            Command(name: "get", summary: "показать значение", arguments: "<алиас>"),
            Command(name: "list", summary: "список алиасов"),
            Command(name: "search", summary: "поиск по алиасу и заметке", arguments: "<текст>"),
            Command(name: "remove", summary: "удалить", arguments: "<алиас>")
        ])
    ]

    /// Suggestions for the current composer text. Empty unless the text is a single
    /// line that starts with a slash.
    static func suggestions(for text: String, limit: Int = 9) -> [CommandSuggestion] {
        guard text.hasPrefix("/"), !text.contains("\n") else { return [] }

        let parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let trimmed = text.trimmingCharacters(in: .whitespaces)

        if parts.count <= 1 {
            return all
                .filter { $0.name.hasPrefix((parts.first ?? "/").lowercased()) }
                .map { command in
                    CommandSuggestion(
                        insert: command.name + (command.wantsTrailingSpace ? " " : ""),
                        title: command.name,
                        detail: command.arguments.map { "\(command.summary) — \($0)" } ?? command.summary
                    )
                }
                .filter { $0.insert != trimmed }
                .prefix(limit)
                .map { $0 }
        }

        guard let root = all.first(where: { $0.name == parts[0].lowercased() }),
              !root.subcommands.isEmpty else {
            return []
        }

        let prefix = parts[1].lowercased()
        return root.subcommands
            .filter { prefix.isEmpty || $0.name.hasPrefix(prefix) }
            .map { sub in
                CommandSuggestion(
                    insert: "\(root.name) \(sub.name)" + (sub.wantsTrailingSpace ? " " : ""),
                    title: "\(root.name) \(sub.name)",
                    detail: sub.arguments.map { "\(sub.summary) — \($0)" } ?? sub.summary
                )
            }
            .filter { $0.insert != trimmed }
            .prefix(limit)
            .map { $0 }
    }

    /// The same content as `/help`, generated so it cannot drift from the palette.
    static var helpText: String {
        var lines = ["**Команды**"]
        for command in all {
            let arguments = command.arguments.map { " \($0)" } ?? ""
            lines.append("- `\(command.name)`\(arguments) — \(command.summary)")
            for sub in command.subcommands {
                let subArguments = sub.arguments.map { " \($0)" } ?? ""
                lines.append("- `\(command.name) \(sub.name)`\(subArguments) — \(sub.summary)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
