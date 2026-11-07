import Foundation

/// Progress-aware anti-loop guard.
///
/// Comparing only the tool-call signature kills legitimate repetition whose
/// result changes (blink on→off→on, a counter, a retry-until-condition loop).
/// This compares the call signature AND a progress signature (per-tool success
/// plus a digest of the result text), and only reports a loop when both are
/// identical again and again.
struct LoopGuard: Sendable {
    private var lastCallSignature: String?
    private var lastProgressSignature: String?
    private var consecutiveRepeats = 0
    let maxIdenticalIterations: Int

    init(maxIdenticalIterations: Int = 3) {
        self.maxIdenticalIterations = maxIdenticalIterations
    }

    /// Returns true when this iteration is a stuck loop and the caller should stop.
    mutating func record(callSignature: String, progressSignature: String) -> Bool {
        if callSignature == lastCallSignature, progressSignature == lastProgressSignature {
            consecutiveRepeats += 1
        } else {
            lastCallSignature = callSignature
            lastProgressSignature = progressSignature
            consecutiveRepeats = 1
        }
        return consecutiveRepeats >= maxIdenticalIterations
    }

    static func callSignature(_ calls: [ToolCall]) -> String {
        calls.map { "\($0.name)\($0.arguments)" }.joined(separator: "|")
    }

    static func progressSignature(_ results: [(name: String, isError: Bool, output: String)]) -> String {
        results.map { result in
            let digest = result.output.prefix(160)
            return "\(result.name)#\(result.isError ? 1 : 0)#\(digest)"
        }.joined(separator: "|")
    }
}

/// Guards against "did not even try": the model refuses without calling a single
/// tool. The orchestrator feeds one corrective message and runs exactly one extra turn.
enum NoAttemptGuard {
    static let correctiveMessage = """
    Ты ещё не попробовал ни одного инструмента. Выполни действие доступными инструментами; \
    Если реально невозможно — объясни это после попыток.
    """

    private static let incapabilityPhrases = [
        "не могу", "невозможно", "нет возможности", "к сожалению, я не",
        "не получится", "i can't", "unable to", "cannot"
    ]

    static func looksLikeIncapability(_ text: String) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let lower = text.lowercased()
        return incapabilityPhrases.contains { lower.contains($0) }
    }

    static func shouldCorrect(toolCallsMadeInRun: Int, finalText: String) -> Bool {
        toolCallsMadeInRun == 0 && looksLikeIncapability(finalText)
    }
}

/// Guards against claiming an action was done when it was not: no tool was
/// called, or the last tool result was an error.
///
/// The hard part is silence. A Russian answer is full of words that look like a
/// success claim to a substring match — "файл создаётся", "готово к запуску",
/// "успешно компилируется" — and a question like "как создаётся файл?" looks like
/// an action request. Matching roots anywhere produced the note on ordinary
/// explanations, which is worse than not having the guard: a warning that fires on
/// every other answer trains the reader to ignore it.
///
/// So both sides are anchored: the request must be an imperative at a sentence
/// start, the claim must be a first-person past or a completion marker near the top
/// of the answer, and the answer must be short — a lie is a confirmation line, not a
/// long explanation.
enum FalseSuccessGuard {
    static let noToolNote = """
    Похоже на отчёт о выполненном действии, но ни один инструмент не вызывался.     Проверь результат сам или переформулируй запрос.
    """

    static let failedToolNote = """
    Последний инструмент вернул ошибку — действие могло не выполниться.     Проверь результат сам.
    """

    static let unverifiedSuccessNote = noToolNote

    /// How much of the answer is inspected for a claim.
    private static let claimWindow = 400
    /// A success claim in a wall of text is not a success claim.
    private static let maxAnswerForClaim = 700

    /// An imperative at the start of a sentence, or an infinitive after a cue word
    /// ("можешь добавить", "нужно создать"). Both halves are needed: a bare substring
    /// match catches "как создаётся файл" and fires on plain explanations.
    private static let requestPattern = try! NSRegularExpression(
        pattern: #"(?i)((^|[.!?,;:]\s+|\n\s*)(создай|сделай|удали|добавь|установи|настрой|запомни|напомни|отправь|скопируй|переименуй|перемести|заархивируй|забронируй|закажи|оплати|запиши|сохрани|проверяй|включи|выключи|собери|поставь)\b)|(\b(можешь|можно|нужно|надо|давай|помоги)\s+(создать|сделать|удалить|добавить|установить|настроить|запомнить|напомнить|отправить|скопировать|переименовать|переместить|заархивировать|забронировать|заказать|оплатить|записать|сохранить|проверять|включить|выключить|собрать|поставить)\b)"#
    )

    private static let schedulePattern = try! NSRegularExpression(
        pattern: #"(?i)\b(каждый час|каждые\s+\d+|по расписанию|поставь напоминание)\b"#
    )

    private static let claimPatterns: [NSRegularExpression] = [
        // "Готово.", "Сделано!", "Выполнено —"
        try! NSRegularExpression(
            pattern: #"(?i)^\s*(готово|сделано|выполнено|done)\b"#
        ),
        // "создал файл", "я удалил папку" — at the start of a sentence
        try! NSRegularExpression(
            pattern: #"(?i)(^|[.!?]\s+|\n\s*)(я\s+)?(создал|создала|удалил|удалила|добавил|добавила|установил|установила|настроил|настроила|запомнил|запомнила|напомнил|напомнила|отправил|отправила|скопировал|скопировала|переименовал|переименовала|заархивировал|забронировал|заказал|оплатил|записал|сохранил|сделал)\b"#
        ),
        // "Файл создан", "Задача удалена" — passive, but with a concrete object
        try! NSRegularExpression(
            pattern: #"(?i)\b(файл|папка|задача|напоминание|запись|архив|письмо|скрипт|проект|коммит|ветка|таблица)\s+(создан|создана|удалён|удален|удалена|установлен|установлена|сохранён|сохранен|сохранена|настроен|настроена|добавлен|добавлена|отправлен|отправлена)\b"#
        )
    ]

    static func looksLikeActionRequest(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let range = NSRange(text.startIndex..., in: text)
        if requestPattern.firstMatch(in: text, range: range) != nil { return true }
        return schedulePattern.firstMatch(in: text, range: range) != nil
    }

    static func claimsActionDone(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= maxAnswerForClaim else { return false }
        let head = String(text.prefix(claimWindow))
        let range = NSRange(head.startIndex..., in: head)
        return claimPatterns.contains { $0.firstMatch(in: head, range: range) != nil }
    }

    static func shouldCorrect(
        userText: String,
        assistantText: String,
        toolCallsInTurn: Int,
        lastToolErrored: Bool
    ) -> Bool {
        guard claimsActionDone(assistantText) else { return false }
        if toolCallsInTurn == 0 {
            return looksLikeActionRequest(userText)
        }
        return lastToolErrored
    }

    /// The note to show, or nil when the answer is consistent with what happened.
    static func note(
        userText: String,
        assistantText: String,
        toolCallsInTurn: Int,
        lastToolErrored: Bool
    ) -> String? {
        guard shouldCorrect(
            userText: userText,
            assistantText: assistantText,
            toolCallsInTurn: toolCallsInTurn,
            lastToolErrored: lastToolErrored
        ) else { return nil }
        return toolCallsInTurn == 0 ? noToolNote : failedToolNote
    }
}

/// Strips leaked internal reasoning from a finished answer.
/// Pure, cheap, runs on every assistant write. Conservative on purpose:
/// unwrapped free-form reasoning is left alone.
enum AssistantTextSanitizer {
    private static let reasoningBlock = try! NSRegularExpression(
        pattern: #"<\s*(thinking|thought|reasoning|scratchpad|analysis|reflection)\s*>[\s\S]*?<\s*/\s*\1\s*>"#,
        options: [.caseInsensitive]
    )

    private static let unclosedReasoningBlock = try! NSRegularExpression(
        pattern: #"<\s*(thinking|thought|reasoning|scratchpad|analysis|reflection)\s*>[\s\S]*$"#,
        options: [.caseInsensitive]
    )

    private static let labelledMarkerLine = try! NSRegularExpression(
        pattern: "^[ \\t]*(?:[>*-][ \\t]*)*(?:" +
            "Размышляю|Размышление|Размышления|Мысль|Мысли|Думаю|План|Планирую|Внутренне|" +
            "Обдумываю|Рассуждение|Рассуждения|" +
            "Thinking|Thought|Thoughts|Reasoning|Plan|Planning|Scratchpad|Analysis|Reflection|" +
            "Internal|Chain[ -]of[ -]thought" +
            ")[ \\t]*:[ \\t]*.*$",
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    private static let bracketMarkerLine = try! NSRegularExpression(
        pattern: "^[ \\t]*(?:[>*-][ \\t]*)*\\[(?:thinking|reasoning|scratchpad|thoughts?|analysis|reflection|internal)\\][ \\t]*.*$",
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    private static let toolPlanningLine = try! NSRegularExpression(
        pattern: "^[ \\t]*(?:[>*-][ \\t]*)*(?:" +
            "(?:Мне нужно (?:вызвать|использовать|применить|выполнить)|" +
            "Сейчас (?:я )?(?:вызову|использую|применю|выполню)|" +
            "Сначала (?:я )?(?:вызову|использую|проверю|узнаю))[ \\t]+" +
            "(?:подходящий[ \\t]+|нужный[ \\t]+)?(?:инструмент|функци[а-яё]*|команд[а-яё]*).*" +
            "|" +
            "(?:I(?:'ll| will| need to)|Let me|First,? I(?:'ll| will))[ \\t]+" +
            "(?:call|use|invoke|run|execute)[ \\t]+(?:the[ \\t]+|a[ \\t]+)?(?:tool|function|command|instrument).*" +
            ")$",
        options: [.caseInsensitive, .anchorsMatchLines]
    )

    private static let trailingSpaces = try! NSRegularExpression(pattern: "[ \\t]+\\n")
    private static let blankRuns = try! NSRegularExpression(pattern: "\\n{3,}")

    /// Streaming-safe: an unclosed reasoning block is dropped immediately so chain
    /// of thought never flashes on screen and then disappears.
    static func sanitizeRealtime(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        let withoutComplete = replace(reasoningBlock, in: raw, with: "")
        return sanitize(replace(unclosedReasoningBlock, in: withoutComplete, with: ""))
    }

    static func sanitize(_ raw: String) -> String {
        guard !raw.isEmpty else { return raw }
        var text = raw
        text = replace(reasoningBlock, in: text, with: "")
        text = replace(labelledMarkerLine, in: text, with: "")
        text = replace(bracketMarkerLine, in: text, with: "")
        text = replace(toolPlanningLine, in: text, with: "")
        text = replace(trailingSpaces, in: text, with: "\n")
        text = replace(blankRuns, in: text, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: template)
    }
}

/// Strips device/platform action claims that are structurally impossible here.
/// Mecha checks phone actions; HARNESS-S checks its own unavailable capabilities,
/// so the model cannot pretend it sent an email or rebooted a machine.
enum CapabilityClaimGuard {
    private static let impossibleClaims: [(pattern: String, note: String)] = [
        ("я отправил (письмо|email|смс)", "отправка почты и SMS не поддерживается"),
        ("я позвонил", "звонки не поддерживаются"),
        ("я включил (фонарик|камеру)", "управление железом недоступно"),
        ("я перезагрузил (компьютер|мак|mac)", "перезагрузка системы не выполняется агентом")
    ]

    static func note(for text: String) -> String? {
        let lower = text.lowercased()
        for claim in impossibleClaims {
            if lower.range(of: claim.pattern, options: .regularExpression) != nil {
                return claim.note
            }
        }
        return nil
    }
}