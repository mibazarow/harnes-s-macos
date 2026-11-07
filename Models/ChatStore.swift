import Foundation
import Observation

@MainActor
@Observable
final class ChatStore {
    private(set) var messages: [ChatMessage]
    private(set) var isStreaming = false
    private(set) var queuedCount = 0
    /// Messages written while a turn is running. Rendered in a dock below the
    /// transcript, never mixed into it: otherwise every new step of the running answer
    /// pushes them up the screen.
    private(set) var queuedMessages: [ChatMessage] = []

    private var streamTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?

    private var replyIndex = 0
    private let services: AppServices?
    private let commands: SlashCommandRouter?
    private let composer = ContextComposer()
    private let client = ProviderClient()
    private var checkpointSummary: String = ""
    private var planMode = false
    private var checkpointCovered: Int = 0
    /// Last message already folded into the checkpoint: everything up to it is replaced
    /// by the summary and must not be sent again.
    private var compactedThroughID: UUID?
    /// Window of the model used on the previous turn. A drop means the history that fit
    /// a minute ago no longer fits, and the request must be compacted before sending.
    private var lastContextWindow: Int?
    private var registry: ToolRegistry?
    private var memoryTouchedThisTurn = false
    private var compactionTask: Task<Void, Never>?
    /// Compaction is expensive and can fail for reasons outside our control (provider
    /// down, summary rejected). Without a cooldown a broken summary would be retried on
    /// every single turn, doubling the cost of a conversation that is already in trouble.
    private var compactionFailures = 0
    private var compactionCooldownUntil: Date?
    private var oldestStoredID: Int64?
    private(set) var hasMoreHistory = false
    private(set) var isLoadingOlder = false
    /// Threshold used for compaction and for the outgoing window. Set from settings.
    var compactionThreshold: Double = 80
    /// Last assembled system prompt, reused for the footer budget so the numbers match.
    private var cachedSystemPrompt = Prompts.system

    init(services: AppServices? = nil) {
        self.services = services
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

    private func appendAssistant() -> UUID {
        let message = ChatMessage(role: .assistant, text: "", state: .streaming)
        messages.append(message)
        return messages[messages.count - 1].id
    }

    private func runTurn(text: String, attachments: [ChatAttachment], assistantID initialID: UUID) async {
        // Each model request gets its own bubble. One long run otherwise piles new
        // reasoning on top of an answer the user has already read.
        var assistantID = initialID
        var stepIndex = 0

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
                await self?.runSubagent(prompt: prompt, readOnly: readOnly, provider: provider, model: model, services: services) ?? ""
            }
        )

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
        Self.logLatency("prep=\(prepMs)ms prompt=\(promptChars)ch messages=\(history.count) model=\(model)")
        let loop = AgentLoop(
            provider: provider,
            model: model,
            registry: registry
        )

        var corrected = false
        var overflowRetried = false

        turn: while true {
        do {
            while true {
                var toolCallsInTurn = 0

                var firstTokenLogged = false
                let requestStart = ContinuousClock.now
                for try await event in loop.run(history: history) {
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
                    case .reasoning(let chunk):
                        appendReasoning(chunk, to: assistantID)
                    case .toolStarted(let name, let summary):
                        toolCallsInTurn += 1
                        addTool(name: name, summary: summary, running: true, to: assistantID)
                    case .toolFinished(let name, let summary, let isError, let imagePath):
                        finishTool(name: name, summary: summary, isError: isError, imagePath: imagePath, in: assistantID)
                    case .usage(let promptTokens, let cacheHit, let cacheMiss):
                        let ratio = promptTokens > 0 ? cacheHit * 100 / promptTokens : 0
                        Self.logLatency("cache hit=\(cacheHit) miss=\(cacheMiss) prompt=\(promptTokens) (\(ratio)%)")
                    case .completed:
                        break
                    }
                }

                if Task.isCancelled { break }

                let answer = messages.first(where: { $0.id == assistantID })?.text ?? ""

                // "Did not even try": refuse without a single tool call.
                // One corrective turn, never a loop.
                if !corrected,
                   NoAttemptGuard.shouldCorrect(
                       toolCallsMadeInRun: toolCallsInTurn,
                       finalText: answer
                   ) {
                    corrected = true
                    history.append(ProviderMessage(role: .system, content: NoAttemptGuard.correctiveMessage))
                    notice("Модель отказалась, не попробовав инструменты — повторяю с требованием выполнить действие.")
                    continue
                }

                break
            }

            finish(assistantID)
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
            if !overflowRetried,
               let providerError = error as? ProviderError,
               providerError.isContextOverflow,
               await compactAfterOverflow(provider: provider, model: model, services: services) {
                overflowRetried = true
                settle(assistantID)
                assistantID = appendAssistant()
                stepIndex = 0
                notice("Провайдер отклонил запрос по длине контекста. Сжал историю и повторяю.")
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
    private func compactAfterOverflow(
        provider: ProviderModel,
        model: String,
        services: AppServices
    ) async -> Bool {
        let system = await buildSystemPrompt(services: services)
        let plan = composer.plan(
            systemPrompt: system,
            messages: promptMessages,
            contextWindow: provider.contextWindow,
            thresholdPercent: min(compactionThreshold, 50),
            summaryTokens: TokenEstimator.tokens(in: checkpointSummary)
        )
        guard !plan.compacted.isEmpty else {
            notice("Сжимать нечего: в истории одно сообщение, и оно само больше окна модели.")
            return false
        }
        return await compact(plan.compacted, provider: provider, model: model, services: services)
    }

    /// Isolated one-shot agent. Its context never leaks into the main chat.
    private func runSubagent(
        prompt: String,
        readOnly: Bool,
        provider: ProviderModel,
        model: String,
        services: AppServices
    ) async -> String {
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

        var answer = ""
        for _ in 0..<8 {
            var streamed = ""
            var calls: [ToolCall] = []

            let stream = client.stream(
                provider: provider,
                model: model,
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
                answer += streamed + "\n[подагент: ошибка \(error.localizedDescription)]"
                break
            }

            answer += streamed

            if calls.isEmpty { break }

            history.append(ProviderMessage(role: .assistant, content: streamed, toolCalls: calls))
            for call in calls {
                let result = await registry.execute(call)
                history.append(ProviderMessage(
                    role: .tool,
                    content: String(result.output.prefix(10_000)),
                    toolCallID: call.id
                ))
            }
        }

        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
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
            model: model
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

        var warnings: [String] = []

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

    private func activeProvider(_ services: AppServices) async throws -> ProviderModel? {
        let providers = try await services.providers.list()
        return providers.first(where: \.isDefault) ?? providers.first
    }

    private func scheduleCompaction(provider: ProviderModel, model: String, services: AppServices) {
        guard compactionTask == nil else { return }
        compactionTask = Task { [weak self] in
            await self?.compactIfNeeded(provider: provider, model: model, services: services)
            self?.compactionTask = nil
        }
    }

    /// Messages that still go to the model: completed, non-system, and not yet folded
    /// into the checkpoint.
    private var promptMessages: [ContextMessage] {
        let compactedIndex = compactedThroughID.flatMap { id in
            messages.firstIndex(where: { $0.id == id })
        }
        return messages.enumerated().compactMap { index, message in
            guard message.state == .complete,
                  message.role != .system,
                  !message.text.isEmpty else { return nil }
            if let compactedIndex, index <= compactedIndex { return nil }
            return ContextMessage(id: index, role: message.role.rawValue, text: message.text)
        }
    }

    /// Folds messages into the checkpoint. Returns false when the model refused, so the
    /// caller can tell the user instead of pretending the history was saved.
    @discardableResult
    private func compact(
        _ contextMessages: [ContextMessage],
        provider: ProviderModel,
        model: String,
        services: AppServices
    ) async -> Bool {
        guard !contextMessages.isEmpty else { return false }

        do {
            let summary = try await services.compaction.summarize(
                messages: contextMessages,
                provider: provider,
                model: model,
                previousSummary: checkpointSummary.isEmpty ? nil : checkpointSummary
            )
            checkpointSummary = summary
            checkpointCovered += contextMessages.count
            if let lastCompacted = contextMessages.last {
                compactedThroughID = messages[lastCompacted.id].id
            }

            try? await services.compaction.saveCheckpoint(
                CompactionService.Checkpoint(
                    summary: summary,
                    coveredMessageCount: checkpointCovered,
                    createdAt: Timestamps.now()
                ),
                database: services.database
            )
            compactionFailures = 0
            compactionCooldownUntil = nil
            return true
        } catch {
            compactionFailures += 1
            // Back off progressively: a second attempt in a minute is reasonable, a
            // tenth is just burning tokens against a broken provider.
            let seconds: TimeInterval = compactionFailures >= 3 ? 600 : 120
            compactionCooldownUntil = Date().addingTimeInterval(seconds)
            Self.logLatency("compaction failed (\(compactionFailures)x): \(error.localizedDescription)")
            return false
        }
    }

    private var compactionCoolingDown: Bool {
        guard let until = compactionCooldownUntil else { return false }
        return Date() < until
    }

    private func compactIfNeeded(provider: ProviderModel, model: String, services: AppServices) async {
        let plan = contextPlan(
            contextWindow: provider.contextWindow,
            thresholdPercent: compactionThreshold,
            summaryTokens: TokenEstimator.tokens(in: checkpointSummary)
        )

        guard plan.didCompact, !plan.compacted.isEmpty else { return }

        // Preflight already handled the case where the request would not fit; a retry
        // here would be the same request again.
        if compactionCoolingDown { return }

        if await compact(plan.compacted, provider: provider, model: model, services: services) {
            notice("История сжата: \(plan.compacted.count) сообщений свёрнуты в саммари. Из базы ничего не удалено.")
        } else {
            notice("Компакция не удалась. Продолжаю с усечённым окном.")
        }
    }

    /// The system prompt, assembled in cache-friendly order: stable parts first, the
    /// style block — which shifts on almost every message — last.
    private func buildSystemPrompt(services: AppServices?) async -> String {
        var parts: [String] = [Prompts.system]

        if let services {
            let skillIndex = await services.skills.promptIndex()
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
    private func prepareWindow(
        contextWindow: Int,
        provider: ProviderModel,
        model: String,
        services: AppServices?
    ) async -> (system: String, included: [ContextMessage]) {
        if let lastContextWindow, lastContextWindow > contextWindow {
            Self.logLatency("window \(lastContextWindow) -> \(contextWindow): preflight compaction")
        }
        lastContextWindow = contextWindow

        var system = await buildSystemPrompt(services: services)
        var plan = composer.plan(
            systemPrompt: system,
            messages: promptMessages,
            contextWindow: contextWindow,
            thresholdPercent: compactionThreshold,
            summaryTokens: TokenEstimator.tokens(in: checkpointSummary)
        )

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
                    messages: promptMessages,
                    contextWindow: contextWindow,
                    thresholdPercent: compactionThreshold,
                    summaryTokens: TokenEstimator.tokens(in: checkpointSummary)
                )
                notice("Сжал историю перед отправкой: \(dropped) сообщений.")
            } else {
                notice("Историю сжать не удалось — \(dropped) старых сообщений не попадут в запрос.")
            }
        }

        cachedSystemPrompt = system
        return (system, plan.included)
    }

    private func buildHistory(
        text: String,
        attachments: [ChatAttachment],
        contextWindow: Int,
        provider: ProviderModel,
        model: String,
        services: AppServices?
    ) async -> [ProviderMessage] {
        let prepared = await prepareWindow(
            contextWindow: contextWindow,
            provider: provider,
            model: model,
            services: services
        )

        var history: [ProviderMessage] = [ProviderMessage(role: .system, content: prepared.system)]

        var prior = prepared.included
        if let last = prior.last, messages[last.id].role == .user {
            prior.removeLast()
        }
        for item in prior {
            let message = messages[item.id]
            let role: ProviderMessage.Role = message.role == .user ? .user : .assistant
            history.append(ProviderMessage(role: role, content: message.text))
        }

        var userText = text
        var images: [Data] = []

        for attachment in attachments {
            switch attachment.kind {
            case .image:
                images.append(attachment.data)
            case .text:
                let body = String(decoding: attachment.data, as: UTF8.self)
                userText += "\n\n<file name=\"\(attachment.name)\" path=\"\(attachment.path)\">\n\(body.prefix(20_000))\n</file>"
            case .folder:
                userText += "\n\n[папка: \(attachment.path)]"
            case .other:
                userText += "\n\n[приложен файл: \(attachment.path)]"
            }
        }

        history.append(ProviderMessage(role: .user, content: userText, images: images))
        return history
    }

    private static func millis(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1_000)
            + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
    }

    private static func logLatency(_ line: String) {
        let url = AppPaths.logsDirectory.appendingPathComponent("latency.log")
        let stamped = Timestamps.now() + " " + line + "\n"
        try? AppPaths.ensureDirectory(AppPaths.logsDirectory)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(stamped.utf8))
            try? handle.close()
        } else {
            try? Data(stamped.utf8).write(to: url)
        }
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

    private func dequeueNext() {
        guard !isStreaming, !queuedMessages.isEmpty else { return }
        var next = queuedMessages.removeFirst()
        queuedCount = queuedMessages.count
        next.state = .complete
        messages.append(next)
        persistUser(next.text, attachments: next.attachments)
        start(next.text, attachments: next.attachments)
    }

    private func append(_ chunk: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text += chunk
    }

    private func appendReasoning(_ chunk: String, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].reasoning = (messages[index].reasoning ?? "") + chunk
    }

    private func addTool(name: String, summary: String, running: Bool, to id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].tools.append(ToolTrace(name: name, summary: summary, isRunning: running))
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
    private func settle(_ id: UUID) -> Bool {
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
        persist(.assistant, text: messages[index].text, reasoning: messages[index].reasoning)
        messages[index].attachments = messages[index].attachments.map { $0.released() }
        return true
    }

    private func finish(_ id: UUID, notice: String? = nil, fallback: String? = nil) {
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
        // the tail, so nothing is actually lost.
        let cap = Self.transcriptCap
        if messages.count > cap {
            messages.removeFirst(messages.count - cap)
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
                return ChatMessage(role: role, text: entry.text, reasoning: entry.reasoning, date: date)
            }
            return ChatMessage(role: role, text: entry.text, reasoning: entry.reasoning)
        }
    }

    private func persistUser(_ text: String, attachments: [ChatAttachment]) {
        let files = attachments.map { "\n[файл: \($0.name)]" }.joined()
        persist(.user, text: text + files, reasoning: nil)
    }

    private func persist(_ role: ChatMessage.Role, text: String, reasoning: String?) {
        guard let services else { return }
        Task.detached(priority: .utility) {
            try? await services.history.append(role: role, text: text, reasoning: reasoning)
        }
    }

    func notice(_ text: String) {
        messages.append(ChatMessage(role: .system, text: text))
    }

    var autopilot = false

    func contextPlan(contextWindow: Int, thresholdPercent: Double, summaryTokens: Int = 0) -> ContextPlan {
        composer.plan(
            systemPrompt: cachedSystemPrompt,
            messages: promptMessages,
            contextWindow: contextWindow,
            thresholdPercent: thresholdPercent,
            summaryTokens: summaryTokens
        )
    }

    private func runCommand(_ input: String) {
        if input == "/clear" {
            clearView()
            return
        }

        if input == "/compact" {
            runCompaction()
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
    private func runCompaction() {
        messages.append(ChatMessage(role: .assistant, text: "…", state: .streaming))
        let messageID = messages[messages.count - 1].id
        isStreaming = true

        commandTask = Task { [weak self] in
            guard let self else { return }
            let text = await self.compactNow()
            guard !Task.isCancelled else { return }
            guard let index = self.messages.firstIndex(where: { $0.id == messageID }) else { return }
            self.messages[index].text = text
            self.messages[index].state = .complete
            self.isStreaming = false
            self.commandTask = nil
            self.dequeueNext()
        }
    }

    /// Manual compaction. Returns a line for the transcript.
    func compactNow() async -> String {
        guard let services else { return "**Ошибка.** База данных недоступна." }

        let provider: ProviderModel?
        do {
            provider = try await activeProvider(services)
        } catch {
            return "**Ошибка.** Не удалось прочитать провайдеров: \(error.localizedDescription)"
        }
        guard let provider else { return "**Ошибка.** Провайдер не подключён." }

        let model = provider.defaultModel ?? provider.models.first ?? ""
        guard !model.isEmpty else { return "**Ошибка.** У провайдера не выбрана модель." }

        let completed = promptMessages
        guard completed.count > 2 else {
            return "Сжимать нечего: в истории \(completed.count) сообщений."
        }

        // The tail is measured in tokens, not messages: six short replies and six long
        // ones are very different amounts of live context.
        let available = Int(Double(provider.contextWindow) * compactionThreshold / 100) - composer.reserveTokens
        let start = composer.tailStart(messages: completed, budget: composer.tailBudget(available: max(available, 2_000)))
        let toCompact = Array(completed.prefix(start))
        guard !toCompact.isEmpty else {
            return "Сжимать нечего: вся история уже в пределах хвоста."
        }

        if await compact(toCompact, provider: provider, model: model, services: services) {
            return "История сжата: \(toCompact.count) сообщений свёрнуты в саммари (\(checkpointSummary.count) симв.). "
                + "В базе ничего не удалено, последние \(completed.count - toCompact.count) сообщений остались как есть."
        }
        return "**Ошибка.** Компакция не удалась. Попробуй ещё раз."
    }

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