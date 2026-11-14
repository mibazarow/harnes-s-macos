import Foundation

/// Runs the provider/tool loop. Emits UI-level events; owns no presentation state.
struct AgentLoop: Sendable {
    let provider: ProviderModel
    let model: String
    let registry: ToolRegistry
    let client = ProviderClient()

    /// Last-resort ceiling, not a loop detector.
    ///
    /// `LoopGuard` is the real detector: it compares calls AND result progress, so
    /// legitimate repetition with changed results, cycles and tool hammering all stop
    /// long before this. The old value of 100 was picked without measurements and sat
    /// below the length of real multi-file tasks; runs that were making progress died
    /// on it. 300 is three times that ceiling and still bounded — after the tool-layer
    /// fixes (error marking, `replace_all`, truncation hints) real runs stay far below
    /// it. Pass nil to remove the ceiling entirely.
    var maxSteps: Int? = 300

    /// Ceiling on the tool output kept inside one run, in characters (~40k tokens).
    ///
    /// A run can call tools a hundred times; without a ceiling the accumulated tool
    /// results alone outgrow the window and the next step fails with a context
    /// overflow. Old results are stubbed rather than dropped, so the model still knows
    /// a call happened and what it returned at a glance.
    var runOutputBudget: Int = 160_000

    enum Event: Sendable {
        /// One model request begins. Everything after it belongs to a new step, which the
        /// UI shows as its own message: reasoning, tools and text per step.
        case stepStarted(Int)
        case delta(String)
        case reasoning(String)
        case toolStarted(name: String, summary: String)
        /// Carries the call id, arguments and output as well: the transcript stores them
        /// so the next request can replay the work instead of pretending it never
        /// happened.
        case toolFinished(
            callID: String,
            name: String,
            arguments: String,
            summary: String,
            output: String,
            isError: Bool,
            imagePath: String?
        )
        case usage(promptTokens: Int, completionTokens: Int, cacheHit: Int, cacheMiss: Int)
        /// The provider cut the answer off at the output ceiling. Carries the reason so
        /// the UI can say "truncated" instead of silently showing half a sentence.
        case truncated(reason: String)
        case completed
    }

    func run(history: [ProviderMessage]) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages = history
                    let schemas = await registry.schemas()

                    var step = 0
                    var loopGuard = LoopGuard()
                    /// Every tool message index in this run, oldest first, so the output
                    /// budget can stub from the front.
                    var toolMessageIndices: [Int] = []
                    while true {
                        if Task.isCancelled { break }

                        continuation.yield(.stepStarted(step))

                        var streamedText = ""
                        var streamedReasoning = ""
                        var calls: [ToolCall] = []
                        var finishReason: String?

                        let stream = client.stream(
                            provider: provider,
                            model: model,
                            messages: messages,
                            tools: schemas
                        )

                        for try await event in stream {
                            if Task.isCancelled { break }
                            switch event {
                            case .delta(let text):
                                streamedText += text
                                continuation.yield(.delta(text))
                            case .reasoning(let text):
                                streamedReasoning += text
                                continuation.yield(.reasoning(text))
                            case .toolCall(let call):
                                calls.append(call)
                            case .usage(let promptTokens, let completionTokens, let cacheHit, let cacheMiss):
                                continuation.yield(.usage(
                                    promptTokens: promptTokens,
                                    completionTokens: completionTokens,
                                    cacheHit: cacheHit,
                                    cacheMiss: cacheMiss
                                ))
                            case .finished(let reason):
                                finishReason = reason
                            }
                        }

                        if Task.isCancelled { break }

                        // A truncated answer is not a finished answer. Continuing with
                        // a new step here is exactly how "it starts over from the top"
                        // happens: the model never saw the end of its own text.
                        if let finishReason, Self.isTruncation(finishReason) {
                            continuation.yield(.truncated(reason: finishReason))
                            continuation.yield(.completed)
                            continuation.finish()
                            return
                        }

                        if calls.isEmpty {
                            continuation.yield(.completed)
                            continuation.finish()
                            return
                        }

                        var assistant = ProviderMessage(
                            role: .assistant,
                            content: streamedText,
                            toolCalls: calls
                        )
                        messages.append(assistant)

                        var outcome: [(name: String, isError: Bool, output: String)] = []

                        for call in calls {
                            if Task.isCancelled { break }
                            let summary = Self.summary(for: call)
                            continuation.yield(.toolStarted(name: call.name, summary: summary))

                            let result = await registry.execute(call)
                            outcome.append((call.name, result.isError, result.output))
                            let imagePath = Self.imagePath(from: result.output)

                            continuation.yield(.toolFinished(
                                callID: call.id,
                                name: call.name,
                                arguments: call.arguments,
                                summary: result.isError ? Self.firstLine(result.output) : summary,
                                output: result.output,
                                isError: result.isError,
                                imagePath: imagePath
                            ))

                            let toolMessage = ProviderMessage(
                                role: .tool,
                                content: Self.toolContent(for: result),
                                toolCallID: call.id
                            )
                            messages.append(toolMessage)
                            toolMessageIndices.append(messages.count - 1)
                        }

                        Self.trimRunOutput(&messages, toolIndices: toolMessageIndices, budget: runOutputBudget)

                        // Progress-aware anti-loop: same calls returning the same
                        // results means we are stuck, not that we are working.
                        let stuck = loopGuard.record(
                            callSignature: LoopGuard.callSignature(calls),
                            progressSignature: LoopGuard.progressSignature(outcome)
                        )
                        if stuck {
                            continuation.yield(.delta(
                                "\n\n_Остановился: повторяю одни и те же вызовы и получаю тот же результат — "
                                + "дальше без изменений не продвинусь. Скажи, что поменять в подходе, "
                                + "и я продолжу с этого места._"
                            ))
                            break
                        }

                        if let maxSteps, step >= maxSteps - 1 {
                            // This is not a loop: LoopGuard above already ruled that out.
                            // Saying "похоже, задача идёт по кругу" on a run that was
                            // making progress trained the user to ignore a real warning,
                            // so the fuse gets its own honest wording.
                            continuation.yield(.delta(
                                "\n\n_Дошёл до предохранителя в \(maxSteps) шагов. "
                                + "Работа не завершена — напиши «продолжай», и я продолжу с этого места._"
                            ))
                            break
                        }
                        assistant.content = streamedText
                        step += 1
                    }

                    continuation.yield(.completed)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Prefix for a failed tool result.
    ///
    /// The provider protocol has no error flag on a `tool` message: the model sees only
    /// `content`. Without a marker a failure like "path обязателен" reads as ordinary
    /// output, so the model retries the same call with a different argument instead of
    /// fixing the cause. Marking happens here, not in `ToolResult`, because the UI
    /// already renders `isError` and would otherwise show the prefix twice.
    static let toolErrorPrefix = "ОШИБКА: "

    static func toolContent(for result: ToolResult) -> String {
        let text = String(result.output.prefix(30_000))
        return result.isError ? toolErrorPrefix + text : text
    }

    /// Stubs the oldest tool results once the run's output exceeds the budget.
    /// The most recent results are what the model actually needs to continue.
    static func trimRunOutput(
        _ messages: inout [ProviderMessage],
        toolIndices: [Int],
        budget: Int
    ) {
        guard budget > 0 else { return }

        var total = messages.reduce(0) { $0 + ($1.role == .tool ? $1.content.count : 0) }
        guard total > budget else { return }

        for index in toolIndices {
            guard index < messages.count, messages[index].role == .tool else { continue }
            let content = messages[index].content
            guard content.count > 200 else { continue }
            let stub = "[ранний вывод этого вызова убран, чтобы уложиться в окно]"
            total -= content.count - stub.count
            messages[index].content = stub
            if total <= budget { break }
        }
    }

    /// Reasons that mean "the output was cut", not "the model stopped".
    static func isTruncation(_ reason: String) -> Bool {
        let value = reason.lowercased()
        return value == "length" || value == "max_tokens" || value == "content_filter"
    }

    private static func summary(for call: ToolCall) -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
        switch call.name {
        case "bash":
            return String((args["command"] as? String ?? "").prefix(90))
        case "fs_read", "fs_write", "edit_file", "ocr":
            return (args["path"] as? String) ?? call.name
        case "fs_list", "fs_glob", "fs_grep":
            return (args["path"] as? String) ?? (args["pattern"] as? String) ?? call.name
        case "webfetch", "browser":
            return (args["url"] as? String) ?? (args["action"] as? String) ?? call.name
        case "websearch":
            return (args["query"] as? String) ?? call.name
        case "memory_search", "secret_search":
            return (args["query"] as? String) ?? call.name
        case "secret_get", "secret_save":
            return (args["alias"] as? String) ?? call.name
        case "skill_install":
            return (args["source"] as? String) ?? call.name
        default:
            return call.name
        }
    }

    private static func imagePath(from output: String) -> String? {
        guard let range = output.range(of: "Скриншот: ") else { return nil }
        let path = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasSuffix(".png") ? path : nil
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n").first ?? "")
    }
}