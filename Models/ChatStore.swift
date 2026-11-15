import Foundation
import Observation

@MainActor
@Observable
final class ChatStore {
    internal(set) var messages: [ChatMessage]
    internal(set) var isStreaming = false
    private(set) var queuedCount = 0
    /// Messages written while a turn is running. Rendered in a dock below the
    /// transcript, never mixed into it: otherwise every new step of the running answer
    /// pushes them up the screen.
    private(set) var queuedMessages: [ChatMessage] = []

    private var streamTask: Task<Void, Never>?
    var commandTask: Task<Void, Never>?

    /// Text that arrived from the provider but is not painted yet. See `scheduleFlush`.
    var pendingText = ""
    var pendingID = UUID()
    var flushTask: Task<Void, Never>?
    var flushDeadline = Date.distantPast

    private var replyIndex = 0
    let services: AppServices?
    private let commands: SlashCommandRouter?
    let composer = ContextComposer()
    private let client = ProviderClient()
    var checkpointSummary: String = ""
    private var planMode = false
    var checkpointCovered: Int = 0
    /// Last message already folded into the checkpoint: everything up to it is replaced
    /// by the summary and must not be sent again.
    var compactedThroughID: UUID?
    /// Window of the model used on the previous turn. A drop means the history that fit
    /// a minute ago no longer fits, and the request must be compacted before sending.
    var lastContextWindow: Int?
    private var registry: ToolRegistry?
    private var memoryTouchedThisTurn = false
    var compactionTask: Task<Void, Never>?
    /// Compaction is expensive and can fail for reasons outside our control (provider
    /// down, summary rejected). Without a cooldown a broken summary would be retried on
    /// every single turn, doubling the cost of a conversation that is already in trouble.
    var compactionFailures = 0
    var compactionCooldownUntil: Date?
    /// Calibration of the local token estimate against provider-reported usage.
    let calibration: TokenCalibration
    /// Scale applied to every "does it fit" decision, refreshed from `calibration`.
    var estimateScale: Double = 1
    /// Serialized tool catalog price for the current run, counted against the window.
    var schemaTokens: Int = 0
    /// First message of the task in progress. Everything before it belongs to closed
    /// tasks and may be pruned from the request.
    var taskStartIndex: Int = 0
    /// Set when a compaction ran in this window: pruning rides along with it so the
    /// cached prefix is reset once, not twice.
    var compactedInWindow = false
    /// A task just closed: prune its finished outputs on the next request.
    var pruneAtBoundary = false
    private var oldestStoredID: Int64?
    private(set) var hasMoreHistory = false
    private(set) var isLoadingOlder = false
    /// Threshold used for compaction and for the outgoing window. Set from settings.
    var compactionThreshold: Double = 80
    /// Last assembled system prompt, reused for the footer budget so the numbers match.
    var cachedSystemPrompt = Prompts.system
    /// Last `contextPlan` result, keyed by everything that plan depends on.
    var planCache: (signature: String, plan: ContextPlan)?

    init(services: AppServices? = nil) {
        self.services = services
        self.calibration = TokenCalibration(database: services?.database)
        self.commands = services.map {
            SlashCommandRouter(
                skills: $0.skills,
                mcp: $0.mcp,
                secrets: $0.secrets,
                memory: $0.memory,
                embeddings: $0.embeddings
            )
        }
        #if DEBUG
        if let demo = DemoTranscript.messages {
            self.messages = demo
            return
        }
        #endif

        self.messages = [
            ChatMessage(
                role: .assistant,
                text: """
                # HARNES-S

                Готов к работе. Подключи провайдера в настройках (⌘,) — и пиши.

                ```bash
                $ harness --status
                workspace  ~/HARNES_S_DATA/workspace
                memory     локальная SQLite
                provider   настраивается
                ```

                Можно кидать файлы прямо в поле ввода: картинки показываются превьюшкой и уходят в модель, текст читается как контекст.
                """
            )
        ]
    }

    func send(_ text: String, attachments: [ChatAttachment] = []) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty || !attachments.isEmpty else { return }

        memoryTouchedThisTurn = false

        if let services {
            Task { await services.style.observe(trimmed) }
        }

        if isStreaming {
            queuedMessages.append(ChatMessage(
                role: .user,
                text: trimmed,
                attachments: attachments,
                state: .queued
            ))
            queuedCount = queuedMessages.count
            return
        }

        // A plan belongs to the turn that produced it. Keeping it forever left a stale
        // checklist hanging under the transcript after the task was long done.
        services?.todos.clearIfFinished()

        messages.append(ChatMessage(role: .user, text: trimmed, attachments: attachments))
        persistUser(trimmed, attachments: attachments)
        start(trimmed, attachments: attachments)
    }

    private func start(_ text: String, attachments: [ChatAttachment]) {
        if attachments.isEmpty, text.hasPrefix("/") {
            runCommand(text)
            return
        }

        let assistantID = appendAssistant()

        isStreaming = true
        streamTask = Task { [weak self] in
            guard let self else { return }
            await self.runTurn(text: text, attachments: attachments, assistantID: assistantID)
        }
    }

    func appendAssistant() -> UUID {
        let message = ChatMessage(role: .assistant, text: "", state: .streaming)
        messages.append(message)
        return messages[messages.count - 1].id
    }

    private func runTurn(text: String, attachments: [ChatAttachment], assistantID initialID: UUID) async {
        // Each model request gets its own bubble. One long run otherwise piles new
        // reasoning on top of an answer the user has already read.
        var assistantID = initialID
        var stepIndex = 0

        // The plan outlives a turn while steps are open; mark it so the model knows the
        // checklist is a continuation, not something it wrote in this turn.
        services?.todos.beginTurn()
        // A skill restriction lives for the turn that read it.
        await services?.skillScope.clear()

        guard let services else {
            await mockReply(for: text, assistantID: assistantID)
            return
        }

        let provider: ProviderModel?
        do {
            provider = try await activeProvider(services)
        } catch {
            finish(assistantID, notice: "Не удалось прочитать провайдеров: \(error.localizedDescription)")
            return
        }

        guard let provider else {
            await mockReply(for: text, assistantID: assistantID)
            return
        }

        let model = provider.defaultModel ?? provider.models.first ?? ""
        guard !model.isEmpty else {
            finish(assistantID, notice: "У активного провайдера не выбрана модель. Открой настройки → Провайдеры.")
            return
        }

        let registry = ToolRegistry(
            workspace: AppPaths.workspaceDirectory,
            memory: services.memory,
            embeddings: services.embeddings,
            secrets: services.secrets,
            skills: services.skills,
            mcp: services.mcp,
            mcpManager: services.mcpManager,
            indexer: services.indexer,
            scheduler: services.scheduler,
            fileSafety: services.fileSafety,
            todos: services.todos,
            readOnly: planMode,
            subagent: { [weak self] prompt, readOnly in
                await self?.runSubagent(
                    prompt: prompt, readOnly: readOnly, provider: provider,
                    model: model, services: services
                ) ?? SubagentOutcome(text: "", error: "сессия закрыта")
            },
            ledger: services.fileLedger,
            skillScope: services.skillScope
        )

        schemaTokens = await registry.schemaTokenCost()
        let prepStart = ContinuousClock.now
        var history = await buildHistory(
            text: text,
            attachments: attachments,
            contextWindow: provider.contextWindow,
            provider: provider,
            model: model,
            services: services
        )
        let prepMs = Self.millis(since: prepStart)
        let promptChars = history.reduce(0) { $0 + $1.content.count }
        Self.logLatency(
            "prep_ms=\(prepMs) prompt_chars=\(promptChars) messages=\(history.count) model=\(model)"
        )
        let calibration = self.calibration
        var loop = AgentLoop(
            provider: provider,
            model: model,
            registry: registry
        )
        loop.onUsage = { measured, estimated in
            await calibration.record(
                providerID: provider.id, model: model, measured: measured, estimated: estimated
            )
        }

        var corrected = false
        var overflowStep = 0

        turn: while true {
        do {
            while true {
                var toolCallsInTurn = 0

                var firstTokenLogged = false
                let requestStart = ContinuousClock.now
                var repetitionStopped = false
                var truncatedReason: String?
                var lastLoopCheck = 0
                var lastReasoningCheck = 0
                stream: for try await event in loop.run(history: history) {
                    if Task.isCancelled { break }
                    if !firstTokenLogged {
                        firstTokenLogged = true
                        Self.logLatency("first_token=\(Self.millis(since: requestStart))ms")
                    }
                    switch event {
                    case .stepStarted:
                        if stepIndex > 0 {
                            settle(assistantID)
                            assistantID = appendAssistant()
                        }
                        stepIndex += 1
                    case .delta(let chunk):
                        append(chunk, to: assistantID)
                        // A degenerate generation repeats itself in the text, not in
                        // the tool calls, so LoopGuard cannot see it. Checking the tail
                        // every few hundred characters is enough to catch it early
                        // without measuring on every token.
                        let soFar = messageText(of: assistantID)
                        let length = soFar.utf8.count
                        if length - lastLoopCheck >= Tuning.repetitionCheckStep {
                            lastLoopCheck = length
                            if RepetitionGuard.isLooping(String(soFar.suffix(Tuning.repetitionTail))) {
                                repetitionStopped = true
                                // The pending tail is part of what looped, so it must
                                // reach the bubble before trimming.
                                break stream
                            }
                        }
                    case .reasoning(let chunk):
                        appendReasoning(chunk, to: assistantID)
                        // Reasoning can loop too, and it burns tokens before the first
                        // visible character ever appears. Same check, different buffer.
                        let reasoningLength = reasoningText(of: assistantID).utf8.count
                        if reasoningLength - lastReasoningCheck >= 400 {
                            lastReasoningCheck = reasoningLength
                            if RepetitionGuard.isLooping(reasoningText(of: assistantID)) {
                                repetitionStopped = true
                                break stream
                            }
                        }
                    case .toolStarted(let name, let summary):
                        toolCallsInTurn += 1
                        addTool(name: name, summary: summary, running: true, to: assistantID)
                    case .toolFinished(let callID, let name, let arguments, let summary, let output, let isError, let imagePath):
                        finishTool(name: name, summary: summary, isError: isError, imagePath: imagePath, in: assistantID)
                        recordExchange(
                            callID: callID,
                            name: name,
                            arguments: arguments,
                            output: output,
                            isError: isError,
                            in: assistantID
                        )
                    case .usage(let promptTokens, let completionTokens, let cacheHit, let cacheMiss):
                        let ratio = promptTokens > 0 ? cacheHit * 100 / promptTokens : 0
                        Self.logLatency(
                            "cache_hit=\(cacheHit) cache_miss=\(cacheMiss) "
                            + "prompt_tokens=\(promptTokens) completion_tokens=\(completionTokens) "
                            + "cache_ratio=\(ratio)%"
                        )
                        estimateScale = await calibration.scale(providerID: provider.id, model: model)
                        do {
                            let cost = UsageService.cost(
                                promptTokens: promptTokens,
                                completionTokens: completionTokens,
                                inputPrice: provider.inputPrice,
                                outputPrice: provider.outputPrice
                            )
                            let totals = await services.usage.add(
                                promptTokens: promptTokens,
                                completionTokens: completionTokens,
                                cachedTokens: cacheHit,
                                cost: cost
                            )
                            spent = totals.cost
                        }
                    case .truncated(let reason):
                        truncatedReason = reason
                    case .completed:
                        break
                    }
                }

                if Task.isCancelled { break }

                if repetitionStopped {
                    trimLoop(assistantID)
                    markLoopWarning(assistantID)
                    break
                }

                if let truncatedReason {
                    markTruncationWarning(assistantID, reason: truncatedReason)
                    break
                }

                let answer = messages.first(where: { $0.id == assistantID })?.text ?? ""

                // "Did not even try": refuse without a single tool call.
                // One corrective turn, never a loop.
                if !corrected,
                   NoAttemptGuard.shouldCorrect(
                       request: text,
                       toolCallsMadeInRun: toolCallsInTurn,
                       finalText: answer
                   ) {
                    corrected = true
                    history.append(ProviderMessage(role: .system, content: NoAttemptGuard.correctiveMessage))
                    // Internal bookkeeping belongs in the log, not in the transcript:
                    // a second bubble and a service note read as two answers.
                    Self.logLatency("no_attempt_guard fired")
                    continue
                }

                break
            }

            let finalStepHadTools = messages.first(where: { $0.id == assistantID })?
                .exchanges.isEmpty == false
            finish(assistantID)
            if !finalStepHadTools {
                recordTaskBoundary(services: services)
            }
            applyFalseSuccessGuard(userText: text, assistantID: assistantID)
            // Compaction is bookkeeping, not part of answering: run it after the
            // answer so it never adds a second model round-trip before the first token.
            scheduleCompaction(provider: provider, model: model, services: services)
            await maybeExtractStyleCard(provider: provider, model: model, services: services)
            return
        } catch {
            // The provider rejected the request as too long. Retrying the same body is
            // pointless, so compact harder and try once more: this is the one case where
            // the estimate was provably low and only the provider knew the real limit.
            if overflowStep < Self.overflowShrinkSteps.count,
               let providerError = error as? ProviderError,
               providerError.isContextOverflow,
               await compactAfterOverflow(
                   provider: provider,
                   model: model,
                   services: services,
                   fraction: Self.overflowShrinkSteps[overflowStep]
               ) {
                let fraction = Self.overflowShrinkSteps[overflowStep]
                overflowStep += 1
                settle(assistantID)
                assistantID = appendAssistant()
                stepIndex = 0
                notice("Провайдер отклонил запрос по длине контекста. Сжал до \(Int(fraction * 100))% бюджета и повторяю.")
                history = await buildHistory(
                    text: text,
                    attachments: attachments,
                    contextWindow: provider.contextWindow,
                    provider: provider,
                    model: model,
                    services: services
                )
                continue turn
            }

            finish(assistantID, notice: "Ошибка: \(error.localizedDescription)")
            return
        }
        }
    }

    /// Aggressive compaction after the provider itself said the prompt is too long.
    /// The threshold drops so the retry has real headroom, not just a few tokens.
    private func runSubagent(
        prompt: String,
        readOnly: Bool,
        provider: ProviderModel,
        model: String,
        services: AppServices
    ) async -> SubagentOutcome {
        let registry = ToolRegistry(
            workspace: AppPaths.workspaceDirectory,
            memory: services.memory,
            embeddings: services.embeddings,
            secrets: nil,
            skills: services.skills,
            mcp: services.mcp,
            mcpManager: services.mcpManager,
            indexer: nil,
            scheduler: nil,
            fileSafety: services.fileSafety,
            todos: nil,
            readOnly: readOnly,
            subagent: nil
        )

        let system = Prompts.system + """

        # Subagent

        Ты — изолированный подагент. Выполни задачу и верни только результат.
        Не спрашивай уточнений, не ссылайся на родительский диалог, не здоровайся.
        Ответ — сжатый, факты и пути, без рассуждений.
        """

        var history: [ProviderMessage] = [
            ProviderMessage(role: .system, content: system),
            ProviderMessage(role: .user, content: prompt)
        ]

        // Read-only investigation is exactly the work a cheap model can do: no edits to
        // get wrong, and the parent only sees the summary.
        let subagentModel = readOnly ? (provider.cheapModel ?? model) : model

        var answer = ""
        var lastError: String?
        var steps = 0
        var callsUsed = 0
        // 12 rounds instead of 8: real investigations need a few reads, and the old cap
        // was silently hit, which is exactly how the subagent came back empty.
        for _ in 0..<12 {
            steps += 1
            var streamed = ""
            var calls: [ToolCall] = []

            let stream = client.stream(
                provider: provider,
                model: subagentModel,
                messages: history,
                tools: await registry.schemas()
            )

            do {
                for try await event in stream {
                    switch event {
                    case .delta(let chunk):
                        streamed += chunk
                    case .toolCall(let call):
                        calls.append(call)
                    default:
                        break
                    }
                }
            } catch {
                lastError = "ошибка стрима: \(error.localizedDescription)"
                answer += streamed
                break
            }

            answer += streamed

            if calls.isEmpty { break }

            history.append(ProviderMessage(role: .assistant, content: streamed, toolCalls: calls))
            callsUsed += calls.count
            for call in calls {
                let result = await registry.execute(call)
                history.append(ProviderMessage(
                    role: .tool,
                    content: String(result.output.prefix(10_000)),
                    toolCallID: call.id
                ))
            }
        }

        // Models often end on a tool call and never say anything. One request without
        // tools forces a textual summary from what was already gathered.
        var text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            history.append(ProviderMessage(
                role: .user,
                content: "Сформулируй итог по уже выполненному: факты и пути, без новых вызовов."
            ))
            do {
                var summary = ""
                for try await event in client.stream(
                    provider: provider, model: subagentModel, messages: history, tools: []
                ) {
                    if case .delta(let chunk) = event { summary += chunk }
                }
                text = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                lastError = lastError ?? "итоговый запрос: \(error.localizedDescription)"
            }
        }

        Self.logLatency("subagent steps=\(steps) calls=\(callsUsed) "
            + "empty=\(text.isEmpty) error=\(lastError ?? "-")")
        return SubagentOutcome(text: text, error: lastError, steps: steps, calls: callsUsed)
    }

    /// Runs the tone-card pass only when it is due: enough samples, not neutral,
    /// and outside the cooldown. Failures are silent by design.
    private func maybeExtractStyleCard(
        provider: ProviderModel,
        model: String,
        services: AppServices
    ) async {
        guard await services.style.shouldExtractCard() else { return }

        let recent = messages
            .filter { $0.role == .user }
            .suffix(30)
            .map(\.text)

        guard let sample = StyleCardExtractor.transcript(from: Array(recent)) else { return }

        let extractor = StyleCardExtractor()
        guard let card = await extractor.extract(
            transcript: sample.text,
            provider: provider,
            model: provider.cheapModel ?? model
        ) else { return }

        await services.style.setCard(card)
    }

    /// Adds an honesty note when the model claims success without confirming evidence.
    /// Mecha appends a note rather than silently trusting the claim; so do we.
    private func applyFalseSuccessGuard(userText: String, assistantID: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == assistantID }) else { return }
        let answer = messages[index].text
        guard !answer.isEmpty else { return }

        let lastErrored = messages[index].tools.last?.isError ?? false
        let toolCalls = messages[index].tools.count

        var warnings: [String] = messages[index].warning.map { [$0] } ?? []

        if let note = FalseSuccessGuard.note(
            userText: userText,
            assistantText: answer,
            toolCallsInTurn: toolCalls,
            lastToolErrored: lastErrored
        ) {
            warnings.append(note)
        }

        if let note = CapabilityClaimGuard.note(for: answer) {
            warnings.append(note + ".")
        }

        // A separate field, not appended text: the model must not read this back as
        // its own previous answer on the next turn.
        messages[index].warning = warnings.isEmpty ? nil : warnings.joined(separator: " ")
    }

    func activeProvider(_ services: AppServices) async throws -> ProviderModel? {
        let providers = try await services.providers.list()
        return providers.first(where: \.isDefault) ?? providers.first
    }

    func buildSystemPrompt(services: AppServices?) async -> String {
        var parts: [String] = [Prompts.system]

        // Project rules go right after the base prompt: they are the most specific
        // instructions in the request and every reference agent loads them.
        let projectInstructions = await ProjectInstructions.shared.load(workspace: AppPaths.workspaceDirectory)
        if !projectInstructions.isEmpty {
            let body = projectInstructions.map { item in
                "## \(item.path)\n\(item.text)"
            }.joined(separator: "\n\n")
            parts.append("""

            # Project instructions
            These files come from the project itself. Follow them for this workspace; they
            never override the safety rules above. A nested file refines a root one.
            \(body)
            """)
        }

        if let services {
            let skillIndex = await services.skills.promptIndex(
                query: messages.last(where: { $0.role == .user })?.text
            )
            if !skillIndex.isEmpty {
                parts.append("""

                # Skills
                Installed skills are reusable instruction sets written for specific tasks. When a request matches a skill, call `skill_read` with its name and follow the loaded instructions. Skills are guidance, not permission: the workspace, safety and confirmation rules above still apply.
                \(skillIndex)
                """)
            }
        }

        if let services, let memories = try? await services.memory.forPrompt(limit: 40), !memories.isEmpty {
            let lines = memories.map { item in
                let mark = item.pinned ? "📌 " : ""
                return "- \(mark)[\(item.kind)] \(item.content)"
            }.joined(separator: "\n")
            if !memoryTouchedThisTurn {
                memoryTouchedThisTurn = true
                try? await services.memory.touch(ids: memories.map(\.id))
            }
            parts.append("""

            # Saved user memory
            These facts are already known. Use them without asking again. Do not restate them to the user just to confirm.
            📌 marks a fact the user asked to remember explicitly; treat it as fixed and never drop it.
            \(lines)
            """)
        }

        if !checkpointSummary.isEmpty {
            parts.append("# Conversation checkpoint (older messages)\n" + checkpointSummary)
        }

        if let services, !services.todos.openItems.isEmpty {
            parts.append("""
            # Open plan
            \(services.todos.summary)
            Keep it current: mark progress with `todowrite` (items, update or complete).
            """)
        }

        if autopilot {
            parts.append("# Autopilot\nThe user disabled tool confirmations. Execute tools immediately without asking for permission. Still refuse: disk formatting, rm -rf on system paths, credential exfiltration, disabling SIP or security settings. Everything else run directly and report the result.")
        }

        // Most volatile part, deliberately last.
        if let services {
            let block = await services.style.promptBlock()
            if !block.isEmpty {
                parts.append(block)
            }
        }

        return parts.joined(separator: "\n\n")
    }

    /// Builds the outgoing window and, when the history does not fit, compacts it first.
    /// This is what makes a switch to a smaller model safe: without it the oldest part
    /// would be dropped silently and the model would never learn what it missed.
    func prepareWindow(
        contextWindow: Int,
        provider: ProviderModel,
        model: String,
        services: AppServices?
    ) async -> (system: String, included: [ContextMessage], stubs: [String: String]) {
        if let lastContextWindow, lastContextWindow > contextWindow {
            Self.logLatency("window \(lastContextWindow) -> \(contextWindow): preflight compaction")
        }
        lastContextWindow = contextWindow
        compactedInWindow = false

        var system = await buildSystemPrompt(services: services)
        let scale = await calibration.scale(providerID: provider.id, model: model)
        estimateScale = scale

        // Prune before the plan: the window must be sized by what actually goes out, or
        // pruning never moves the compaction threshold and the session still compacts
        // as if the history were full.
        let pruning = plannedPruning()
        if !pruning.isEmpty {
            Self.logLatency(
                "pruned tool_results=\(pruning.replacements.count) saved_tokens=\(pruning.savedTokens) "
                + "first_index=\(pruning.firstPrunedIndex ?? -1)"
            )
        }
        pruneAtBoundary = false
        var plan = composer.plan(
            systemPrompt: system,
            messages: promptMessages(pruning: pruning.replacements),
            contextWindow: contextWindow,
            thresholdPercent: compactionThreshold,
            summaryTokens: TokenEstimator.tokens(in: checkpointSummary),
            estimateScale: scale,
            toolTokens: schemaTokens
        )

        // Measured pressure: the plan can say "fits" while the provider's last answer
        // reported a prompt above the threshold. Then the measurement wins.
        if let services {
            let budget = composer.budget(for: contextWindow, thresholdPercent: compactionThreshold)
            let measured = await calibration.lastMeasured(providerID: provider.id, model: model)
            let decision = PromptPressure.decide(
                estimated: plan.usedTokens,
                measured: measured,
                usable: budget.usable,
                threshold: budget.thresholdTokens
            )
            if decision.source == .measured {
                Self.logLatency(
                    "budget_source=measured estimated=\(plan.usedTokens) measured=\(measured ?? 0)"
                )
            }
            if decision.overThreshold, plan.compacted.isEmpty, !compactionCoolingDown {
                let all = promptMessages(pruning: pruning.replacements)
                let fold = Array(all.prefix(max(all.count / 2, 1)))
                if fold.count < all.count,
                   await compact(fold, provider: provider, model: model, services: services) {
                    system = await buildSystemPrompt(services: services)
                    compactedInWindow = true
                    plan = composer.plan(
                        systemPrompt: system,
                        messages: promptMessages(pruning: pruning.replacements),
                        contextWindow: contextWindow,
                        thresholdPercent: compactionThreshold,
                        summaryTokens: TokenEstimator.tokens(in: checkpointSummary),
                        estimateScale: scale,
                        toolTokens: schemaTokens
                    )
                    notice("История сжата по факту: провайдер сообщил \(measured ?? 0) токенов.")
                }
            }
        }

        if let services, !plan.compacted.isEmpty, compactionCoolingDown {
            // A failed summary was already reported. Retrying it on every turn would
            // double the cost of a conversation that is already in trouble.
            Self.logLatency("preflight compaction skipped: cooldown")
        } else if let services, !plan.compacted.isEmpty {
            let dropped = plan.compacted.count
            let compacted = await compact(plan.compacted, provider: provider, model: model, services: services)

            if compacted {
                // The checkpoint lives inside the system prompt, so both are rebuilt.
                system = await buildSystemPrompt(services: services)
                plan = composer.plan(
                    systemPrompt: system,
                    messages: promptMessages(pruning: pruning.replacements),
                    contextWindow: contextWindow,
                    thresholdPercent: compactionThreshold,
                    summaryTokens: TokenEstimator.tokens(in: checkpointSummary),
                    estimateScale: scale,
                    toolTokens: schemaTokens
                )
                compactedInWindow = true
                notice("Сжал историю перед отправкой: \(dropped) сообщений.")
            } else {
                notice("Историю сжать не удалось — \(dropped) старых сообщений не попадут в запрос.")
            }
        }

        cachedSystemPrompt = system
        return (system, plan.included, pruning.replacements)
    }

    private static func millis(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    /// Kept open between writes: open+seek+close per line was measurable on a long
    /// session. A stat per write keeps the handle honest if the file is rotated or
    /// deleted under us, which is cheaper than reopening every time.
    private static let latencyLock = NSLock()
    private static var latencyHandle: FileHandle?

    static func logLatency(_ line: String) {
        let url = AppPaths.logsDirectory.appendingPathComponent("latency.log")
        try? AppPaths.ensureDirectory(AppPaths.logsDirectory)
        let stamped = Data((Timestamps.now() + " " + line + "\n").utf8)

        latencyLock.lock()
        defer { latencyLock.unlock() }
        if latencyHandle == nil || !FileManager.default.fileExists(atPath: url.path) {
            try? latencyHandle?.close()
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            latencyHandle = try? FileHandle(forWritingTo: url)
            try? latencyHandle?.seekToEnd()
        }
        try? latencyHandle?.write(contentsOf: stamped)
    }

    private func mockReply(for text: String, assistantID: UUID) async {
        let reply = nextReply()
        let chunks = Self.chunks(of: reply)
        for chunk in chunks {
            if Task.isCancelled { break }
            try? await Task.sleep(for: .milliseconds(16))
            append(chunk, to: assistantID)
        }
        finish(assistantID, notice: nil, fallback: "Провайдер не подключён. Открой настройки → Провайдеры.")
    }

    func stop() {
        // The buffer is part of the answer: flush before the bubble is frozen, or the
        // last few hundred milliseconds of text vanish on Stop.
        flush()
        streamTask?.cancel()
        commandTask?.cancel()
        streamTask = nil
        commandTask = nil
        let dropped = queuedMessages.count
        for var message in queuedMessages {
            message.state = .cancelled
            messages.append(message)
            // Kept in storage too: the text must survive a restart even though it was
            // never sent to the model.
            persistUser(message.text, attachments: message.attachments)
        }
        queuedMessages.removeAll()
        queuedCount = 0
        isStreaming = false

        if dropped > 0 {
            notice("Очередь очищена: \(dropped) сообщений не отправлено.")
        }

        for index in messages.indices where messages[index].state == .streaming {
            messages[index].state = .complete
            if messages[index].text.isEmpty {
                messages[index].text = "_Остановлено._"
            }
            for toolIndex in messages[index].tools.indices where messages[index].tools[toolIndex].isRunning {
                messages[index].tools[toolIndex].isRunning = false
            }
        }
    }

    func dequeueNext() {
        guard !isStreaming, !queuedMessages.isEmpty else { return }
        var next = queuedMessages.removeFirst()
        queuedCount = queuedMessages.count
        next.state = .complete
        messages.append(next)
        persistUser(next.text, attachments: next.attachments)
        start(next.text, attachments: next.attachments)
    }

    private func addTool(name: String, summary: String, running: Bool, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].tools.append(ToolTrace(name: name, summary: summary, isRunning: running))
    }

    private func recordExchange(
        callID: String,
        name: String,
        arguments: String,
        output: String,
        isError: Bool,
        in id: UUID
    ) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].exchanges.append(ToolExchange(
            callID: callID,
            name: name,
            arguments: arguments,
            output: output,
            isError: isError
        ))
    }

    private func finishTool(name: String, summary: String, isError: Bool, imagePath: String?, in id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        if let toolIndex = messages[index].tools.lastIndex(where: { $0.isRunning && $0.name == name }) {
            messages[index].tools[toolIndex].summary = summary
            messages[index].tools[toolIndex].isError = isError
            messages[index].tools[toolIndex].isRunning = false
            messages[index].tools[toolIndex].imagePath = imagePath
        } else {
            messages[index].tools.append(ToolTrace(
                name: name,
                summary: summary,
                isError: isError,
                isRunning: false,
                imagePath: imagePath
            ))
        }
    }

    /// Closes one step of a run: sanitizes, marks it complete and writes it to storage.
    /// Returns false when the step produced nothing, in which case its bubble is dropped.
    @discardableResult
    func settle(_ id: UUID) -> Bool {
        // Everything still buffered belongs to this bubble: a step boundary must not
        // silently swallow the last few hundred milliseconds of an answer.
        flush()
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return false }

        messages[index].text = AssistantTextSanitizer.sanitizeRealtime(messages[index].text)
        let text = messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
        let reasoning = messages[index].reasoning?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !text.isEmpty || !reasoning.isEmpty || !messages[index].tools.isEmpty else {
            messages.remove(at: index)
            return false
        }

        messages[index].state = .complete
        for toolIndex in messages[index].tools.indices {
            messages[index].tools[toolIndex].isRunning = false
        }
        persist(
            .assistant,
            text: messages[index].text,
            reasoning: messages[index].reasoning,
            exchanges: messages[index].exchanges
        )
        messages[index].attachments = messages[index].attachments.map { $0.released() }
        return true
    }

    func finish(_ id: UUID, notice: String? = nil, fallback: String? = nil) {
        // The turn is over: paint what is left, then forget the timer entirely so a
        // late flush cannot append to a bubble that is already marked complete.
        flush()
        guard let index = messages.firstIndex(where: { $0.id == id }) else {
            isStreaming = false
            return
        }

        messages[index].text = AssistantTextSanitizer.sanitizeRealtime(messages[index].text)

        if let notice {
            messages[index].text += (messages[index].text.isEmpty ? "" : "\n\n") + "**\(notice)**"
        }
        if messages[index].text.isEmpty, let fallback {
            messages[index].text = fallback
        }
        if messages[index].text.isEmpty, messages[index].reasoning == nil, messages[index].tools.isEmpty {
            messages[index].text = "_Пустой ответ._"
        }

        settle(id)
        releaseUserAttachments()

        // Keep the in-memory view bounded. Storage keeps everything; a restart restores
        // the tail, so nothing is actually lost. The cap counts what the user sees:
        // steps are collapsed into runs for display, so raw bubbles are not the right
        // unit. A hard raw ceiling still guards against one pathological run.
        let drop = ChatMessage.trimToDisplayLimit(messages, limit: Self.transcriptCap)
        if drop > 0 {
            messages.removeFirst(drop)
        }
        if messages.count > Self.rawMessageCeiling {
            messages.removeFirst(messages.count - Self.rawMessageCeiling)
        }

        // One line per run in the same file as the latency numbers: the measurement
        // Правка 3 asks for, without a schema or a second source of truth.
        let stats = ToolUsageStats.analyze(messages)
        if !stats.isEmpty {
            Self.logLatency("tool_stats steps=\(stats.steps) calls=\(stats.toolCalls) "
                + "longest=\(stats.longestRunTool ?? "-")x\(stats.longestRun)")
        }

        isStreaming = false
        streamTask = nil
        dequeueNext()
    }

    /// Payloads were only needed for the request that produced them.
    private func releaseUserAttachments() {
        for index in messages.indices where messages[index].role == .user {
            messages[index].attachments = messages[index].attachments.map { $0.released() }
        }
    }

    /// Messages held in the view at once. Storage keeps everything; this is only how
    /// much the list keeps in memory. Scrolling up pulls older pages.
    static let transcriptCap = 200
    /// Absolute ceiling on raw bubbles, independent of grouping. A single run that
    /// never ends would otherwise grow the array without bound while showing one group.
    static let rawMessageCeiling = 1_000
    /// One page of history, both on launch and on every scroll-up.
    static let pageSize = 200

    var isPlanMode: Bool { planMode }

    func setPlanMode(_ enabled: Bool) {
        planMode = enabled
        notice(enabled
            ? "Режим плана: только чтение. Правки и опасные команды отключены, пока не выключишь."
            : "Режим плана выключен: инструменты снова могут менять файлы.")
    }

    func warmUpMCP() async {
        guard let services else { return }
        _ = await services.mcpManager.tools()
    }

    func loadHistory() async {
        if let services {
            spent = await services.usage.totals().cost
        }

        guard let services else { return }

        // Restore the compaction checkpoint, otherwise a saved summary would be
        // silently dropped on restart.
        if let checkpoint = try? await services.compaction.loadCheckpoint(database: services.database) {
            checkpointSummary = checkpoint.summary
            checkpointCovered = checkpoint.coveredMessageCount
        }

        let stored: [StoredMessage]
        do {
            stored = try await services.history.recent(limit: Self.pageSize)
        } catch {
            messages.append(ChatMessage(role: .system, text: "История не загрузилась: \(error.localizedDescription)"))
            return
        }
        guard !stored.isEmpty else { return }
        guard messages.count <= 1 else { return }

        let restored = Self.restore(stored)
        guard !restored.isEmpty else { return }
        messages = restored
        oldestStoredID = stored.first?.id
        hasMoreHistory = (try? await services.history.hasOlder(than: stored[0].id)) ?? false

        // Rebuild the compaction boundary from stored counts. The checkpoint holds how
        // many messages are already summarized; everything older than the uncovered
        // tail is one of them, so it must not be sent again on top of the summary.
        if checkpointCovered > 0 {
            let total = (try? await services.history.count()) ?? restored.count
            let coveredInView = Self.coveredInView(total: total, covered: checkpointCovered, inView: restored.count)
            if coveredInView > 0 {
                compactedThroughID = restored[coveredInView - 1].id
            }
        }
    }

    /// Scroll-up pagination: one older page per call, nothing is removed.
    func loadOlder() async {
        guard let services, let oldestStoredID, !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }

        do {
            let stored = try await services.history.older(than: oldestStoredID, limit: Self.pageSize)
            guard !stored.isEmpty else {
                hasMoreHistory = false
                return
            }
            let restored = Self.restore(stored)
            messages.insert(contentsOf: restored, at: 0)
            self.oldestStoredID = stored.first?.id
            hasMoreHistory = (try? await services.history.hasOlder(than: stored[0].id)) ?? false
        } catch {
            hasMoreHistory = false
        }
    }

    /// How many of the restored messages are already inside the checkpoint.
    /// `uncovered` messages at the end of storage are the ones the checkpoint does not
    /// cover; everything before them is summarized.
    nonisolated static func coveredInView(total: Int, covered: Int, inView: Int) -> Int {
        let uncovered = max(total - covered, 0)
        return min(max(inView - uncovered, 0), inView)
    }

    private static func restore(_ stored: [StoredMessage]) -> [ChatMessage] {
        stored.compactMap { entry in
            guard let role = ChatMessage.Role(rawValue: entry.role), role != .system else { return nil }
            if let date = ISO8601DateFormatter().date(from: entry.createdAt) {
                return ChatMessage(
                    role: role,
                    text: entry.text,
                    reasoning: entry.reasoning,
                    exchanges: entry.exchanges,
                    date: date
                )
            }
            return ChatMessage(
                role: role,
                text: entry.text,
                reasoning: entry.reasoning,
                exchanges: entry.exchanges
            )
        }
    }

    private func persistUser(_ text: String, attachments: [ChatAttachment]) {
        let files = attachments.map { "\n[файл: \($0.name)]" }.joined()
        persist(.user, text: text + files, reasoning: nil)
    }

    private func persist(
        _ role: ChatMessage.Role,
        text: String,
        reasoning: String?,
        exchanges: [ToolExchange] = []
    ) {
        guard let services else { return }
        Task.detached(priority: .utility) {
            try? await services.history.append(
                role: role,
                text: text,
                reasoning: reasoning,
                exchanges: exchanges
            )
        }
    }

    func notice(_ text: String) {
        messages.append(ChatMessage(role: .system, text: text))
    }

    var autopilot = false
    /// Money spent so far in the provider's currency. Zero when no prices are set.
    var spent: Double = 0

    private func runCommand(_ input: String) {
        if input == "/clear" {
            clearView()
            return
        }

        if input == "/compact" {
            runCompaction()
            return
        }

        if input == "/checkpoint" {
            // Close the current task by hand: its finished tool output leaves the next
            // request, and a long task is folded into the checkpoint once.
            recordTaskBoundary(services: services)
            notice("Контрольная точка: результаты закрытой задачи уйдут в следующий запрос сжатыми; полный текст остаётся в базе.")
            return
        }

        if input == "/stats" {
            let stats = ToolUsageStats.analyze(messages)
            messages.append(ChatMessage(role: .assistant, text: stats.summary))
            return
        }

        guard let commands else {
            messages.append(ChatMessage(
                role: .assistant,
                text: "**Ошибка.** База данных недоступна, команды отключены."
            ))
            return
        }

        messages.append(ChatMessage(role: .assistant, text: "…", state: .streaming))
        let messageID = messages[messages.count - 1].id
        isStreaming = true

        commandTask = Task { [weak self] in
            guard let self else { return }
            let result = await commands.handle(input)
            guard !Task.isCancelled else { return }
            guard let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
            self.messages[index].text = result.isError ? "**Ошибка.** \(result.text)" : result.text
            self.messages[index].state = .complete
            self.isStreaming = false
            self.commandTask = nil
            self.dequeueNext()
        }
    }

    /// `/compact`: folds everything except the last few messages into the checkpoint
    /// regardless of the fill level. Same machinery as automatic compaction.
    func clearView() {
        stop()
        oldestStoredID = nil
        hasMoreHistory = false
        messages.removeAll()
        messages.append(ChatMessage(
            role: .system,
            text: "Вид очищен. История остаётся в базе — здесь пока только демо-слой."
        ))
    }

    private func nextReply() -> String {
        let replies = [
            "Принято. Провайдер ещё не подключён, поэтому это заглушка — остальное уже работает: markdown, подсветка, темы, очередь сообщений, файлы.",
            "Ок. Вот как выглядит JSON и таблица:\n\n```json\n{\n  \"chat\": \"harness\",\n  \"workspace\": \"~/HARNES_S_DATA/workspace\",\n  \"streaming\": true\n}\n```\n\n| слой | статус |\n|---|---|\n| UI | готов |\n| LLM | настраивается |\n| память | локальная |",
            "Короткий ответ в одну строку — как в терминале."
        ]
        let reply = replies[replyIndex % replies.count]
        replyIndex += 1
        return reply
    }

    private static func chunks(of text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= 3 && character.isWhitespace {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}