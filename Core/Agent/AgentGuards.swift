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
enum FalseSuccessGuard {
    static let unverifiedSuccessNote = """
    Внимание: инструмент не подтвердил успешное выполнение — действие могло быть НЕ выполнено. \
    Проверь результат сам или переформулируй запрос.
    """

    private static let actionRoots = [
        "созда", "добав", "поставь", "постав", "установ", "удали", "удал",
        "переимену", "отправ", "позвон", "заархив", "архив", "запомни", "настрой",
        "напомн", "включи", "выключи", "проверяй", "каждый час", "по расписанию",
        "скопиру", "перемест", "собер", "заброниру", "закаж", "оплат", "запиши", "сохрани"
    ]

    private static let successRoots = [
        "созда", "создана", "создал", "добав", "поставил", "установил", "удалил",
        "переименова", "отправил", "позвонил", "заархив", "запомнил", "настроил",
        "напомн", "включил", "готово", "выполнено", "сделано", "сделал",
        "сохранён", "сохранен", "успешно", "записал"
    ]

    static func looksLikeActionRequest(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        return actionRoots.contains { lower.contains($0) }
    }

    static func claimsActionDone(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let lower = text.lowercased()
        return successRoots.contains { lower.contains($0) }
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