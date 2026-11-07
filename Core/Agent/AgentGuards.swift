import Foundation

/// Progress-aware anti-loop guard.
///
/// Comparing only the tool-call signature kills legitimate repetition whose result
/// changes (blink on→off→on, a counter, a retry-until-condition loop). This compares
/// the call signature AND a progress signature (per-tool success plus a digest of the
/// result text).
///
/// Two shapes are detected, because models get stuck in both:
/// - the same step repeated N times in a row (`A A A`), and
/// - a short cycle of steps with no progress (`A B A B`, `A B C A B C`).
/// The second shape is the common one on real tasks — read, edit, test, read, edit,
/// test — and it used to run all the way to the 100-step ceiling.
struct LoopGuard: Sendable {
    private struct Step: Equatable {
        let call: String
        let progress: String
    }

    private var steps: [Step] = []
    let maxIdenticalIterations: Int
    /// How many steps are remembered for cycle detection.
    let window: Int
    /// Longest cycle considered. Three covers read→edit→test and its variants.
    let maxPeriod: Int

    init(maxIdenticalIterations: Int = 3, window: Int = 12, maxPeriod: Int = 3) {
        self.maxIdenticalIterations = maxIdenticalIterations
        self.window = window
        self.maxPeriod = maxPeriod
    }

    /// Returns true when this iteration is a stuck loop and the caller should stop.
    mutating func record(callSignature: String, progressSignature: String) -> Bool {
        steps.append(Step(call: callSignature, progress: progressSignature))
        if steps.count > window {
            steps.removeFirst(steps.count - window)
        }

        // Straight repeat: the same step, unchanged, several times running.
        if steps.count >= maxIdenticalIterations {
            let tail = Array(steps.suffix(maxIdenticalIterations))
            if tail.allSatisfy({ $0 == tail[0] }) { return true }
        }

        // Cycle: the last `period * 2` steps are two identical blocks. Progress has to
        // be identical too, otherwise the cycle is doing work (a poll that changes).
        for period in 2...maxPeriod {
            let needed = period * 2
            guard steps.count >= needed else { continue }
            let tail = Array(steps.suffix(needed))
            let first = Array(tail.prefix(period))
            let second = Array(tail.suffix(period))
            if first == second { return true }
        }
        return false
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
/// Catches a degenerating generation: the model starts repeating a word, a phrase or a
/// whole sentence and never stops.
///
/// This is a known failure of low-temperature and greedy sampling on long outputs, and
/// it is invisible to `LoopGuard`: no tool is called, so there is nothing to compare.
/// The check runs on the streamed text itself and only looks at its tail, because a
/// loop always forms at the end. Work is done on UTF-8 bytes — repetition is a byte
/// property, and byte comparison is far cheaper than grapheme comparison.
enum RepetitionGuard {
    /// Shorter answers cannot be a loop worth stopping.
    private static let minLength = 500
    /// Only the tail is inspected.
    private static let window = 1_200
    /// A unit repeated this many times is a loop, not emphasis.
    private static let minRepeats = 4
    /// Longest repeating unit considered: longer than this is a paragraph, not a stutter.
    private static let maxUnit = 300
    /// A unit must carry this many letters or digits to count; this keeps `----` and
    /// runs of whitespace from tripping the guard.
    private static let minUnitVisible = 12
    /// Identical consecutive lines that count as a loop.
    private static let minRepeatedLines = 6
    private static let minLineLength = 20
    /// Identical consecutive words that count as a loop.
    private static let minRepeatedWords = 14

    static func isLooping(_ text: String) -> Bool {
        loopCut(in: text) != nil
    }

    /// The answer cut at the start of the repeating run, or the text unchanged.
    static func trimmed(_ text: String) -> String {
        guard let cut = loopCut(in: text) else { return text }
        let head = String(decoding: text.utf8.prefix(cut), as: UTF8.self)
        return head.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Byte offset where the repeating run starts, or nil when the text is healthy.
    static func loopCut(in text: String) -> Int? {
        let bytes = Array(text.utf8)
        let count = bytes.count
        guard count >= minLength else { return nil }

        let start = max(0, count - window)
        let tail = Array(bytes[start...])

        if let offset = repeatedUnitStart(tail) { return start + offset }
        if let offset = repeatedLineStart(tail) { return start + offset }
        if let offset = repeatedWordStart(tail) { return start + offset }
        return nil
    }

    // MARK: - Shapes

    private static func repeatedUnitStart(_ tail: [UInt8]) -> Int? {
        let count = tail.count
        let limit = min(maxUnit, count / minRepeats)
        guard limit >= 1 else { return nil }

        for length in 1...limit {
            let runStart = count - length * minRepeats
            guard runStart >= 0 else { continue }

            let unit = Array(tail[runStart..<runStart + length])
            let visible = unit.reduce(0) { $0 + (isVisible($1) ? 1 : 0) }
            guard visible >= minUnitVisible else { continue }

            var matches = true
            for repeatIndex in 1..<minRepeats {
                let from = runStart + repeatIndex * length
                if !tail[from..<from + length].elementsEqual(unit) {
                    matches = false
                    break
                }
            }
            guard matches else { continue }

            // Walk back over the whole run, not just the four copies that tripped the
            // check: the answer is trimmed at the first repetition, so nothing of the
            // loop is left on screen.
            var cut = runStart
            while cut - length >= 0, tail[(cut - length)..<cut].elementsEqual(unit) {
                cut -= length
            }
            return cut
        }
        return nil
    }

    private static func repeatedLineStart(_ tail: [UInt8]) -> Int? {
        let text = String(decoding: tail, as: UTF8.self)
        var lines: [(text: String, offset: Int)] = []
        var offset = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                lines.append((trimmed, offset))
            }
            offset += raw.utf8.count + 1
        }

        guard lines.count >= minRepeatedLines else { return nil }
        let last = Array(lines.suffix(minRepeatedLines))
        guard let first = last.first, first.text.count >= minLineLength else { return nil }
        guard last.allSatisfy({ $0.text == first.text }) else { return nil }

        var index = lines.count - minRepeatedLines
        while index > 0, lines[index - 1].text == first.text {
            index -= 1
        }
        return lines[index].offset
    }

    private static func repeatedWordStart(_ tail: [UInt8]) -> Int? {
        let text = String(decoding: tail, as: UTF8.self)
        var words: [(value: String, offset: Int)] = []
        var offset = 0
        var index = text.startIndex

        while index < text.endIndex {
            if text[index].isWhitespace {
                offset += text[index].utf8.count
                index = text.index(after: index)
                continue
            }
            let start = index
            let startOffset = offset
            while index < text.endIndex, !text[index].isWhitespace {
                offset += text[index].utf8.count
                index = text.index(after: index)
            }
            words.append((String(text[start..<index]).lowercased(), startOffset))
        }

        guard words.count >= minRepeatedWords else { return nil }
        let last = Array(words.suffix(minRepeatedWords))
        guard let first = last.first, first.value.count >= 2 else { return nil }
        guard last.allSatisfy({ $0.value == first.value }) else { return nil }

        var runIndex = words.count - minRepeatedWords
        while runIndex > 0, words[runIndex - 1].value == first.value {
            runIndex -= 1
        }
        return words[runIndex].offset
    }

    private static func isVisible(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)      // 0-9
            || (byte >= 0x41 && byte <= 0x5A) // A-Z
            || (byte >= 0x61 && byte <= 0x7A) // a-z
            || byte >= 0x80                   // any non-ASCII (Cyrillic, CJK, emoji)
    }
}
