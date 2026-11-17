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
    /// Stable prompt-cache key for this session. A provider keeps one K/V cache per
    /// slot; without pinning, a request can land on a cold slot and lose the prefix.
    var cacheKey: String? = nil

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

    /// Called with `(measured promptTokens, local estimate)` for the request that just
    /// answered. Keeping it here means the estimate covers exactly the messages the
    /// provider saw, including tool results added between steps.
    var onUsage: (@Sendable (Int, Int) async -> Void)?

    func run(history: [ProviderMessage]) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var messages = history
                    let schemas = await registry.schemas()

                    var step = 0
                    var loopGuard = LoopGuard()
                    /// Append-only invariant (R24): inside a run the history grows at the
                    /// end. Rewriting an earlier tool message would diverge the cached
                    /// prefix and make every following step cold.
                    var runOutputChars = 0
                    // Plan drift counter: nudging only after the model itself opted into
                    // a plan avoids nagging runs that never used todowrite.
                    var sawTodo = false
                    var callsSinceTodoUpdate = 0
                    while true {
                        if Task.isCancelled { break }

                        continuation.yield(.stepStarted(step))

                        var streamedText = ""
                        var streamedReasoning = ""
                        var calls: [ToolCall] = []
                        var finishReason: String?

                        let estimated = Self.estimateTokens(messages: messages, schemas: schemas)
                        let stream = client.stream(
                            provider: provider,
                            model: model,
                            messages: messages,
                            tools: schemas,
                            cacheKey: cacheKey
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
                                if let onUsage { await onUsage(promptTokens, estimated) }
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

                        // Read-only calls cannot affect each other, and providers often
                        // return several at once. Anything mutating is a barrier: a write
                        // must still see the read that came before it in the same batch.
                        for call in calls {
                            continuation.yield(.toolStarted(name: call.name, summary: Self.summary(for: call)))
                        }
                        let results = await Self.runCalls(calls, registry: registry)
                        for (index, call) in calls.enumerated() {
                            guard let result = results[index] else { break }
                            outcome.append((call.name, result.isError, result.output))
                            let imagePath = Self.imagePath(from: result.output)

                            continuation.yield(.toolFinished(
                                callID: call.id,
                                name: call.name,
                                arguments: call.arguments,
                                summary: result.isError ? Self.firstLine(result.output) : Self.summary(for: call),
                                output: result.output,
                                isError: result.isError,
                                imagePath: imagePath
                            ))

                            // The budget is applied when the result is inserted, not by
                            // rewriting old messages later: the historical prefix must
                            // stay byte-identical for the provider's cache.
                            let content = Self.fitToolContent(
                                Self.toolContent(for: result),
                                remaining: runOutputBudget - runOutputChars
                            )
                            runOutputChars += content.count
                            messages.append(ProviderMessage(
                                role: .tool, content: content, toolCallID: call.id
                            ))
                        }

                        if calls.contains(where: { $0.name == "todowrite" }) {
                            sawTodo = true
                            callsSinceTodoUpdate = 0
                        } else {
                            callsSinceTodoUpdate += calls.count
                        }
                        if sawTodo,
                           let nudge = registry.todoNudge(callsSinceUpdate: callsSinceTodoUpdate) {
                            // New message at the end, not an edit of a sent one: same
                            // nudge, no prefix break (R24.1).
                            messages.append(ProviderMessage(role: .system, content: nudge))
                            callsSinceTodoUpdate = 0
                        }

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

    /// What the request costs by the app's own estimator: serialized message text,
    /// every tool call and result measured as JSON, image tiles at a flat price, and the
    /// tool catalog. The same basis as `ChatStore.promptMessages`, so compaction and
    /// calibration talk about the same number.
    static func estimateTokens(messages: [ProviderMessage], schemas: [ProviderToolSchema]) -> Int {
        var total = 0
        for message in messages {
            switch message.role {
            case .tool:
                total += ToolCost.result(message.content)
            default:
                total += TokenEstimator.jsonTokens(in: message.content)
                for call in message.toolCalls {
                    total += ToolCost.call(name: call.name, arguments: call.arguments, id: call.id)
                }
            }
            // Images are priced by area, not by count: a screenshot and an icon are not
            // the same request (R15.7).
            total += message.images.reduce(0) { $0 + ImageCost.tokens(in: $1) }
        }
        return total + ToolCost.catalog(schemas)
    }

    /// Read-only tools that can run concurrently. Consecutive runs of these execute in
    /// one task group; a mutating call splits the batch and runs alone, so ordering
    /// between a read and a later write is preserved.
    static let parallelSafeTools: Set<String> = [
        "fs_read", "fs_list", "fs_grep", "fs_glob", "fs_tree", "read_many",
        "search_code", "memory_search", "websearch", "webfetch"
    ]

    /// Results in call order; `nil` means the run was cancelled before that call.
    static func runCalls(_ calls: [ToolCall], registry: ToolRegistry) async -> [ToolResult?] {
        var results = [ToolResult?](repeating: nil, count: calls.count)
        var index = 0
        while index < calls.count {
            if Task.isCancelled { break }
            if parallelSafeTools.contains(calls[index].name) {
                var end = index
                while end < calls.count, parallelSafeTools.contains(calls[end].name) { end += 1 }
                let batch = Array(calls[index..<end])
                let base = index
                await withTaskGroup(of: (Int, ToolResult).self) { group in
                    for (offset, call) in batch.enumerated() {
                        group.addTask { (base + offset, await registry.execute(call)) }
                    }
                    for await (slot, result) in group {
                        results[slot] = result
                    }
                }
                index = end
            } else {
                results[index] = await registry.execute(calls[index])
                index += 1
            }
        }
        return results
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

    static let runOutputStub = "[вывод этого вызова не помещается в бюджет прогона]"

    /// Fits one tool result into what is left of the run's output budget. Cutting at
    /// insertion means the message is never rewritten afterwards (R24.2).
    static func fitToolContent(_ content: String, remaining: Int) -> String {
        guard remaining > 0 else { return runOutputStub }
        guard content.count > remaining else { return content }
        let marker = "\n[обрезано: бюджет прогона]"
        let keep = max(remaining - marker.count, 0)
        return String(content.prefix(keep)) + marker
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
        // `[image: /path.png]` is the explicit marker; screenshots keep their older
        // human-readable prefix so existing traces still render.
        if let start = output.range(of: "[image: "),
           let end = output.range(of: "]", range: start.upperBound..<output.endIndex) {
            return String(output[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        guard let range = output.range(of: "Скриншот: ") else { return nil }
        let path = output[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasSuffix(".png") ? path : nil
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n").first ?? "")
    }
}