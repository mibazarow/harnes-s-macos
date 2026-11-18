import Foundation

/// R32.2: pick the deferred tools a turn needs instead of hiding all of them.
///
/// Sixty-one tools travel as one line each, which costs context on every request and
/// still leaves the model guessing which of them is relevant. This ranks deferred tools
/// against the user's message and sends the top ones in full; the rest stay as a name
/// with a short line, so the model still knows they exist. The total stays inside
/// `Tuning.schemaTokenBudget`.
///
/// The ranking is BM25 over the tool name, its description and a small Russian alias
/// list. The aliases exist because every description is in English and the messages are
/// not: "поставь будильник" has no word in common with "Schedule a prompt".
enum ToolSelector {
    /// Full schemas sent for deferred tools. Six is enough for a real task and leaves
    /// room for the core catalog.
    static let maxExpanded = 6
    /// Below this the match is noise; such a tool stays compact.
    static let minScore = 0.9

    /// Russian intent words per tool. Kept short: this is a hint for the ranker, not a
    /// translation of the catalog.
    static let aliases: [String: [String]] = [
        "schedule_add": ["будильник", "напомни", "напоминание", "расписание", "таймер"],
        "schedule_list": ["напоминания", "расписания", "будильники"],
        "schedule_remove": ["убери", "удали", "напоминание"],
        "calendar": ["встреча", "событие", "календарь", "напоминание", "созвон"],
        "shortcut": ["шорткат", "ярлык", "команда", "автоматизация"],
        "app_script": ["скрипт", "applescript", "приложение"],
        "contacts": ["контакт", "телефон", "адрес", "человек", "почта"],
        "share": ["письмо", "отправить", "почта", "поделиться"],
        "notify": ["уведомление", "сообщение", "оповести"],
        "windows": ["окно", "окна", "приложение", "переключись"],
        "apps": ["приложение", "запусти", "открой", "закрой"],
        "ui": ["нажми", "кнопка", "элемент", "интерфейс"],
        "mouse": ["мышь", "клик", "курсор", "наведи"],
        "keyboard": ["клавиша", "напечатай", "горячая"],
        "clipboard": ["буфер", "скопируй", "вставь"],
        "system": ["система", "сведения", "версия", "батарея"],
        "permissions": ["разрешение", "грант", "доступ", "права"],
        "process": ["процесс", "фоновый", "запусти", "останови"],
        "display": ["монитор", "экран", "яркость", "разрешение"],
        "power": ["громкость", "звук", "яркость", "сон", "блокировка", "перезагрузка"],
        "network": ["сеть", "wifi", "вайфай", "vpn", "прокси", "роутер"],
        "watch": ["подожди", "изменение", "файл", "сборка"],
        "spotlight": ["поиск", "найди", "spotlight"],
        "files": ["файл", "диск", "том", "образ", "dmg"],
        "activity": ["активность", "экспорт", "лог"],
        "screenshot": ["скриншот", "снимок", "экран"],
        "ocr": ["текст", "распознай", "картинка"],
        "browser": ["браузер", "сайт", "страница", "залогинься"],
        "webfetch": ["страница", "сайт", "ссылка", "url"],
        "websearch": ["найди", "поиск", "интернет", "новости"],
        "doc_read": ["документ", "docx", "pdf", "текст"],
        "doc_write": ["документ", "создай", "docx", "pdf"],
        "image_read": ["картинка", "изображение", "фото"],
        "app_logs": ["лог", "журнал", "ошибка", "приложение"],
        "index_workspace": ["индекс", "проиндексируй", "поиск"],
        "search_code": ["код", "найди", "функция", "символ"],
        "project_overview": ["проект", "стек", "сборка", "тесты"],
        "git": ["git", "ветка", "пуш", "мерж"],
        "git_log": ["git", "история", "коммиты"],
        "git_stash": ["git", "спрячь", "stash"],
        "fs_tree": ["дерево", "структура", "папка"],
        "fs_glob": ["файлы", "шаблон", "найди"],
        "trash_paths": ["корзина", "удали", "файл"],
        "undo_list": ["отмена", "верни", "undo"],
        "restore_trashed": ["верни", "корзина", "восстанови"],
        "file_versions": ["версия", "история", "файл"],
        "restore_version": ["версия", "восстанови", "верни"],
        "secret_save": ["секрет", "пароль", "токен", "ключ"],
        "secret_get": ["секрет", "пароль", "токен", "ключ"],
        "secret_search": ["секрет", "пароль", "токен", "ключ"],
        "skill_list": ["навык", "скилл", "skill"],
        "skill_read": ["навык", "скилл", "skill"],
        "skill_learn": ["навык", "запомни", "процедура", "skill"],
        "skill_install": ["навык", "установи", "skill"],
        "skill_remove": ["навык", "удали", "skill"],
        "mcp_list": ["mcp", "сервер"],
        "mcp_tools": ["mcp", "инструменты", "сервер"],
        "observe": ["наблюдай", "экран", "запись"],
        "settings": ["настройки", "обои", "тема"],
        "launchd": ["автозапуск", "служба", "демон"],
        "workspace": ["рабочая", "папка", "workspace"]
    ]

    struct Selection: Sendable {
        /// Tools whose full schema is sent.
        let expanded: Set<String>
        /// Deferred tools that stay as a name and one line.
        let compact: Set<String>
        /// Tools dropped from this request to stay inside the budget.
        let dropped: Set<String>
        let tokens: Int
    }

    static func select(
        definitions: [ToolDefinition],
        query: String,
        budget: Int = Tuning.schemaTokenBudget,
        recent: Set<String> = [],
        loaded: Set<String> = []
    ) -> Selection {
        let core = definitions.filter { $0.exposure == .core || $0.exposure == .normal }
        let deferred = definitions.filter { $0.exposure == .deferred }
        let scores = rank(deferred, query: query)

        func key(_ definition: ToolDefinition) -> (Int, Double) {
            let boost = boosted(
                definition.name, query: query, recent: recent, loaded: loaded
            ) ? 1 : 0
            return (boost, scores[definition.name] ?? 0)
        }
        let ordered = deferred.sorted { left, right in
            let leftKey = key(left)
            let rightKey = key(right)
            if leftKey.0 != rightKey.0 { return leftKey.0 > rightKey.0 }
            if leftKey.1 != rightKey.1 { return leftKey.1 > rightKey.1 }
            return left.name < right.name
        }

        // Everything starts as a one-liner; the exact request cost is measured, not
        // estimated, because a per-tool overhead would otherwise put the total over the
        // budget while every individual sum said it fits.
        var compact = Set(ordered.map(\.name))
        var expanded = Set<String>()
        var dropped = Set<String>()

        func cost() -> Int {
            measure(core: core, deferred: ordered, expanded: expanded, compact: compact)
        }

        // First: shed one-liners until the base catalog fits. Lowest score goes first.
        if cost() > budget {
            for definition in ordered.reversed() where cost() > budget {
                compact.remove(definition.name)
                dropped.insert(definition.name)
            }
        }

        // Then: promote the relevant ones to full schemas. A promotion that does not
        // fit is paid for by shedding the least relevant one-liners, not by giving up:
        // the point of the ranking is that the relevant tool is the one that stays.
        func shedCandidate(excluding excluded: Set<String>) -> String? {
            ordered
                .filter { compact.contains($0.name) && !excluded.contains($0.name) }
                .filter { !boosted($0.name, query: query, recent: recent, loaded: loaded) }
                .last?
                .name
        }

        for definition in ordered {
            guard expanded.count < maxExpanded else { break }
            let explicit = boosted(
                definition.name, query: query, recent: recent, loaded: loaded
            )
            guard explicit || (scores[definition.name] ?? 0) >= minScore else { break }

            expanded.insert(definition.name)
            compact.remove(definition.name)
            while cost() > budget, let victim = shedCandidate(excluding: expanded) {
                compact.remove(victim)
                dropped.insert(victim)
            }
            if cost() > budget {
                expanded.remove(definition.name)
                compact.insert(definition.name)
                continue
            }
        }

        // A selection that fits nothing useful must not fall back to the whole catalog:
        // keep a small set of everyday tools visible instead.
        if expanded.isEmpty, dropped.count > deferred.count / 2 {
            for name in safeFallback where dropped.contains(name) {
                dropped.remove(name)
                compact.insert(name)
                if cost() > budget {
                    compact.remove(name)
                    dropped.insert(name)
                }
            }
        }

        return Selection(
            expanded: expanded, compact: compact, dropped: dropped, tokens: cost()
        )
    }

    /// Exact cost of the request the selector is about to describe.
    static func measure(
        core: [ToolDefinition],
        deferred: [ToolDefinition],
        expanded: Set<String>,
        compact: Set<String>
    ) -> Int {
        var schemas: [ProviderToolSchema] = core.map {
            ProviderToolSchema(
                name: $0.name, description: $0.description, parameters: $0.parameters
            )
        }
        for definition in deferred {
            if expanded.contains(definition.name) {
                schemas.append(ProviderToolSchema(
                    name: definition.name,
                    description: definition.description,
                    parameters: definition.parameters
                ))
            } else if compact.contains(definition.name) {
                schemas.append(ProviderToolSchema(
                    name: definition.name,
                    description: ToolRegistry.compactDescription(definition),
                    parameters: [
                        "type": AnySendable("object"),
                        "properties": AnySendable([String: Any]())
                    ]
                ))
            }
        }
        return ToolCost.catalog(schemas)
    }

    /// R32.2: when ranking produces nothing usable, degrade to a small safe set rather
    /// than dumping the whole catalog into the request.
    static let safeFallback: Set<String> = [
        "project_overview", "search_code", "fs_tree", "git", "process",
        "webfetch", "browser", "permissions"
    ]

    static func boosted(
        _ name: String,
        query: String,
        recent: Set<String>,
        loaded: Set<String>
    ) -> Bool {
        if recent.contains(name) || loaded.contains(name) { return true }
        let lower = query.lowercased()
        guard !lower.isEmpty else { return false }
        if lower.contains(name.lowercased()) { return true }
        return (aliases[name] ?? []).contains { lower.contains($0) }
    }

    /// BM25 over name, description and aliases. The corpus is tiny, so a linear scan
    /// with real document frequencies is both exact and cheap.
    static func rank(_ definitions: [ToolDefinition], query: String) -> [String: Double] {
        let documents = definitions.map { definition -> (name: String, tokens: [String]) in
            let text = ([definition.name, definition.description]
                + (aliases[definition.name] ?? []))
                .joined(separator: " ")
            return (definition.name, tokenize(text))
        }
        let queryTokens = tokenize(query)
        guard !queryTokens.isEmpty else { return [:] }

        let averageLength = Double(documents.map(\.tokens.count).reduce(0, +))
            / Double(max(documents.count, 1))
        let k1 = 1.2
        let b = 0.75

        var result: [String: Double] = [:]
        for document in documents {
            var score = 0.0
            let length = Double(document.tokens.count)
            for token in queryTokens {
                let frequency = document.tokens.filter { matches($0, token) }.count
                guard frequency > 0 else { continue }
                let documentFrequency = documents.filter { doc in
                    doc.tokens.contains { matches($0, token) }
                }.count
                let idf = log(1 + (Double(documents.count) - Double(documentFrequency) + 0.5)
                    / (Double(documentFrequency) + 0.5))
                let denominator = Double(frequency)
                    + k1 * (1 - b + b * length / max(averageLength, 1))
                score += idf * (Double(frequency) * (k1 + 1)) / denominator
            }
            result[document.name] = score
        }
        return result
    }

    /// Prefix match on the first four letters: "будильник" finds "будильники",
    /// "reminder" finds "reminders", and unrelated words stay unrelated.
    static func matches(_ documentToken: String, _ queryToken: String) -> Bool {
        if documentToken == queryToken { return true }
        let prefix = min(4, min(documentToken.count, queryToken.count))
        guard prefix >= 3 else { return false }
        return documentToken.hasPrefix(String(queryToken.prefix(prefix)))
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
    }
}
