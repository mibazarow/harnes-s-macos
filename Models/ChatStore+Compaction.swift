import Foundation

/// Compaction: the checkpoint, the outgoing window and the request that folds old
/// messages into a summary. Split out of `ChatStore` so the file reads as a chat store,
/// not as a kitchen sink. Behaviour is unchanged; the fields it touches are internal
/// for exactly this reason.
extension ChatStore {
    func compactAfterOverflow(
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

    func scheduleCompaction(provider: ProviderModel, model: String, services: AppServices) {
        guard compactionTask == nil else { return }
        compactionTask = Task { [weak self] in
            await self?.compactIfNeeded(provider: provider, model: model, services: services)
            self?.compactionTask = nil
        }
    }

    /// Messages that still go to the model: completed, non-system, and not yet folded
    /// into the checkpoint.

    var promptMessages: [ContextMessage] {
        let compactedIndex = compactedThroughID.flatMap { id in
            messages.firstIndex(where: { $0.id == id })
        }
        return messages.enumerated().compactMap { index, message in
            guard message.state == .complete,
                  message.role != .system,
                  !message.text.isEmpty || !message.exchanges.isEmpty else { return nil }
            if let compactedIndex, index <= compactedIndex { return nil }
            // Tool calls and results travel with the message, so their text has to be
            // part of the budget too.
            let extra = message.exchanges
                .map { "\($0.name)\($0.arguments)\n\($0.output)" }
                .joined(separator: "\n")
            return ContextMessage(
                id: index,
                role: message.role.rawValue,
                text: message.text,
                extra: extra
            )
        }
    }

    /// Folds messages into the checkpoint. Returns false when the model refused, so the
    /// caller can tell the user instead of pretending the history was saved.
    @discardableResult

    func compact(
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

    var compactionCoolingDown: Bool {
        guard let until = compactionCooldownUntil else { return false }
        return Date() < until
    }

    func compactIfNeeded(provider: ProviderModel, model: String, services: AppServices) async {
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

    func buildHistory(
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
            if message.role == .user {
                history.append(ProviderMessage(role: .user, content: message.text))
                continue
            }

            // Replay the work, not just the prose: an assistant turn that called tools
            // goes back as `assistant(tool_calls)` followed by one `tool` message per
            // call, exactly as the provider emitted it. Without this the model cannot
            // tell what it already did and starts the task over.
            if !message.exchanges.isEmpty {
                history.append(ProviderMessage(
                    role: .assistant,
                    content: message.text,
                    toolCalls: message.exchanges.map {
                        ToolCall(id: $0.callID, name: $0.name, arguments: $0.arguments)
                    }
                ))
                for exchange in message.exchanges {
                    history.append(ProviderMessage(
                        role: .tool,
                        content: exchange.output,
                        toolCallID: exchange.callID
                    ))
                }
                continue
            }

            // A step with no text and no calls carries nothing; sending an empty
            // assistant turn is out of distribution and confuses some providers.
            guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            history.append(ProviderMessage(role: .assistant, content: message.text))
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

    func contextPlan(contextWindow: Int, thresholdPercent: Double, summaryTokens: Int = 0) -> ContextPlan {
        // Planning tokenizes the whole history. The composer asks for the plan on every
        // body pass, so during streaming this ran twice per token. The signature covers
        // everything the plan depends on, so a hit is exact rather than approximate.
        let last = messages.last
        let signature = [
            String(contextWindow),
            String(thresholdPercent),
            String(summaryTokens),
            String(messages.count),
            last?.id.uuidString ?? "-",
            String(last?.text.count ?? 0),
            String(last?.reasoning?.count ?? 0),
            String(last?.tools.count ?? 0),
            String(last?.exchanges.count ?? 0),
            String(last?.exchanges.reduce(0) { $0 + $1.output.count } ?? 0),
            String(cachedSystemPrompt.count)
        ].joined(separator: "|")
        if let cache = planCache, cache.signature == signature {
            return cache.plan
        }

        let plan = composer.plan(
            systemPrompt: cachedSystemPrompt,
            messages: promptMessages,
            contextWindow: contextWindow,
            thresholdPercent: thresholdPercent,
            summaryTokens: summaryTokens
        )
        planCache = (signature, plan)
        return plan
    }

    func runCompaction() {
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
        // Everything that is sent but is not a history message: system prompt and the
        // existing checkpoint. Without subtracting them the boundary is optimistic.
        let system = await buildSystemPrompt(services: services)
        let fixed = TokenEstimator.tokens(in: system) + TokenEstimator.tokens(in: checkpointSummary)
        let budget = max(available - fixed, 2_000)

        // Compaction costs a request and destroys detail. If the history already fits,
        // there is nothing to buy: report the numbers and leave storage alone.
        if composer.fits(completed, budget: budget) {
            let used = completed.reduce(0) { $0 + $1.tokens }
            return "Сжимать нечего: вся история помещается в контекст (\(used) токенов из \(budget))."
        }

        let start = composer.tailStart(messages: completed, budget: composer.tailBudget(available: budget))
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
}
