import Foundation

/// Compaction: the checkpoint, the outgoing window and the request that folds old
/// messages into a summary. Split out of `ChatStore` so the file reads as a chat store,
/// not as a kitchen sink. Behaviour is unchanged; the fields it touches are internal
/// for exactly this reason.
extension ChatStore {
    /// How hard to shrink after the provider rejected the request as too long. The
    /// first retry should not change much; the last one has to, or the turn is lost.
    static let overflowShrinkSteps: [Double] = [0.85, 0.7, 0.5, 0.35]

    func compactAfterOverflow(
        provider: ProviderModel,
        model: String,
        services: AppServices,
        fraction: Double = 0.5
    ) async -> Bool {
        // The provider already said the request does not fit; a previous summary
        // failure is not a reason to skip the one action that can recover the turn.
        compactionCooldownUntil = nil
        let system = await buildSystemPrompt(services: services)
        let plan = composer.plan(
            systemPrompt: system,
            messages: promptMessages,
            contextWindow: provider.contextWindow,
            thresholdPercent: min(100, max(10, fraction * 100)),
            summaryTokens: TokenEstimator.tokens(in: checkpointSummary),
            estimateScale: estimateScale,
            toolTokens: schemaTokens
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
            guard let self else { return }
            // The task outlives the turn: the provider may have been switched in
            // settings while the answer was streaming. Capture is only a hint.
            let resolved: (ProviderModel, String)
            if let fresh = try? await self.activeProvider(services),
               let name = fresh.defaultModel ?? fresh.models.first, !name.isEmpty {
                resolved = (fresh, name)
            } else {
                Self.logLatency("compaction: provider resolve failed, using caller's")
                resolved = (provider, model)
            }
            await self.compactIfNeeded(provider: resolved.0, model: resolved.1, services: services)
            self.compactionTask = nil
        }
    }

    /// A task closed when the model answered without calling a tool. Everything before
    /// this point belongs to finished work: its tool output may be pruned from the next
    /// request, and a long task is folded into the checkpoint once.
    func recordTaskBoundary(services: AppServices?) {
        let start = max(taskStartIndex, 0)
        guard start < messages.count else { return }
        let task = Array(messages[start..<messages.count])
        let toolResults = task.reduce(0) { $0 + $1.exchanges.count }
        guard !task.isEmpty else { return }

        taskStartIndex = messages.count
        if toolResults > 0 { pruneAtBoundary = true }
        Self.logLatency("task boundary messages=\(task.count) tool_results=\(toolResults)")

        guard let services, task.count > Tuning.taskBoundarySummaryMessages, toolResults > 0 else {
            return
        }
        summarizeClosedTask(task, services: services)
    }

    private func summarizeClosedTask(_ task: [ChatMessage], services: AppServices) {
        guard compactionTask == nil, !compactionCoolingDown else { return }
        compactionTask = Task { [weak self] in
            guard let self else { return }
            defer { self.compactionTask = nil }
            guard let provider = try? await self.activeProvider(services),
                  let model = provider.defaultModel ?? provider.models.first, !model.isEmpty else { return }

            let start = self.messages.firstIndex(where: { $0.id == task.first?.id }) ?? 0
            let coveredIndex = self.compactedThroughID.flatMap { id in
                self.messages.firstIndex(where: { $0.id == id })
            }

            var items: [ContextMessage] = []
            for (offset, message) in task.enumerated() {
                let index = start + offset
                if let coveredIndex, index <= coveredIndex { continue }
                guard message.state == .complete, message.role != .system,
                      !message.text.isEmpty || !message.exchanges.isEmpty else { continue }
                let extraTokens = message.exchanges.reduce(0) { sum, exchange in
                    sum + ToolCost.exchange(
                        name: exchange.name, arguments: exchange.arguments, output: exchange.output
                    )
                }
                items.append(ContextMessage(
                    id: index, role: message.role.rawValue, text: message.text, extraTokens: extraTokens
                ))
            }
            guard !items.isEmpty else { return }

            // Folded silently on purpose: the closed task is routine housekeeping,
            // the user should not see a message per finished task.
            _ = await self.compact(items, provider: provider, model: model, services: services)
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
            // Tool calls and results travel with the message. Their cost is measured
            // on serialized JSON, envelope and escaping included.
            let extraTokens = message.exchanges.reduce(0) { sum, exchange in
                sum + ToolCost.exchange(
                    name: exchange.name, arguments: exchange.arguments, output: exchange.output
                )
            }
            return ContextMessage(
                id: index,
                role: message.role.rawValue,
                text: message.text,
                extraTokens: extraTokens
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
        let beforeTokens = promptMessages.reduce(0) { $0 + $1.tokens }

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
            recordCompactionEffectiveness(
                before: beforeTokens, services: services
            )
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
        let scale = await calibration.scale(providerID: provider.id, model: model)
        let plan = contextPlan(
            contextWindow: provider.contextWindow,
            thresholdPercent: compactionThreshold,
            summaryTokens: TokenEstimator.tokens(in: checkpointSummary),
            estimateScale: scale
        )

        guard plan.didCompact, !plan.compacted.isEmpty else {
            await compactIfMeasuredHot(provider: provider, model: model, services: services)
            return
        }

        // Preflight already handled the case where the request would not fit; a retry
        // here would be the same request again.
        if compactionCoolingDown { return }

        var guardState = Self.loadCompactionGuard(services: services)
        if let blocked = guardState.blockedUntil, blocked > Date() {
            Self.logLatency("compaction blocked by strikes until \(blocked.ISO8601Format())")
            return
        }
        if guardState.blockedUntil != nil {
            // Recovery: one attempt after the block expires, not a full unblock.
            guardState.blockedUntil = nil
            Self.saveCompactionGuard(guardState, services: services)
        }

        if await compact(plan.compacted, provider: provider, model: model, services: services) {
            notice("История сжата: \(plan.compacted.count) сообщений свёрнуты в саммари. Из базы ничего не удалено.")
        } else {
            // Rejected summaries must not rotate the history: a truncated summary would
            // silently drop context. Say what actually happened.
            notice("Сжатие не удалось: \(plan.compacted.count) сообщений сохранены без изменений, история не тронута. Повтори /compact.")
        }
    }

    /// Reactive compaction: the plan may say "fits", but the provider already reported a
    /// prompt above 60% of the usable input budget. Waiting for the next turn is how a
    /// single large step overflows the window before the fold happens.
    private func compactIfMeasuredHot(
        provider: ProviderModel,
        model: String,
        services: AppServices
    ) async {
        guard let measured = await calibration.lastMeasured(providerID: provider.id, model: model) else { return }
        let usable = composer.budget(
            for: provider.contextWindow, thresholdPercent: compactionThreshold
        ).usable
        guard measured > Int(Double(usable) * 0.6) else { return }
        guard !compactionCoolingDown else { return }

        let all = promptMessages
        guard all.count > 4 else { return }
        let fold = Array(all.prefix(all.count / 2))
        guard !fold.isEmpty else { return }

        if await compact(fold, provider: provider, model: model, services: services) {
            notice("История сжата заранее: \(fold.count) сообщений (\(measured) из \(usable) токенов у провайдера).")
        }
    }

    // MARK: - Anti-thrash

    struct CompactionGuard {
        var strikes = 0
        var blockedUntil: Date?
    }

    static func loadCompactionGuard(services: AppServices) -> CompactionGuard {
        var guardState = CompactionGuard()
        let values: [String: String] = (try? services.database.queue.read { db in
            var result: [String: String] = [:]
            if let raw = try AppStateStore.read(db, key: "compaction.strikes") { result["strikes"] = raw }
            if let raw = try AppStateStore.read(db, key: "compaction.blockedUntil") { result["until"] = raw }
            return result
        }) ?? [:]
        if let raw = values["strikes"], let value = Int(raw) { guardState.strikes = value }
        if let raw = values["until"], !raw.isEmpty,
           let date = ISO8601DateFormatter().date(from: raw) { guardState.blockedUntil = date }
        return guardState
    }

    static func saveCompactionGuard(_ guardState: CompactionGuard, services: AppServices) {
        try? services.database.queue.write { db in
            try AppStateStore.write(db, key: "compaction.strikes", value: String(guardState.strikes))
            try AppStateStore.write(
                db, key: "compaction.blockedUntil",
                value: guardState.blockedUntil?.ISO8601Format() ?? ""
            )
        }
    }

    static func resetCompactionGuard(services: AppServices) {
        saveCompactionGuard(CompactionGuard(), services: services)
    }

    /// A compaction that does not reduce the volume is a loop, not a fix. Three in a row
    /// block the automatic path for half an hour; the manual path clears the block.
    func recordCompactionEffectiveness(before: Int, services: AppServices) {
        let after = promptMessages.reduce(0) { $0 + $1.tokens }
        var guardState = Self.loadCompactionGuard(services: services)
        if before > 0, after >= Int(Double(before) * 0.9) {
            guardState.strikes += 1
            if guardState.strikes >= 3 {
                guardState.blockedUntil = Date().addingTimeInterval(1_800)
            }
        } else {
            guardState.strikes = 0
        }
        Self.saveCompactionGuard(guardState, services: services)
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

        // Finished tool output is replaced by a stub in the request only: storage keeps
        // the full text, so nothing is lost for a later turn or for a manual review.
        let pruningCutoff = min(taskStartIndex, messages.count)
        let stubs = ToolOutputPruner.replacements(
            messages: messages,
            included: prepared.included,
            cutoffIndex: pruningCutoff,
            mode: Tuning.toolOutputPruning,
            compactionHappened: compactedInWindow || pruneAtBoundary
        )
        if !stubs.isEmpty {
            Self.logLatency("pruned tool_results=\(stubs.count) cutoff=\(pruningCutoff)")
        }
        pruneAtBoundary = false

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
                        content: stubs[exchange.callID] ?? exchange.output,
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

    func contextPlan(
        contextWindow: Int,
        thresholdPercent: Double,
        summaryTokens: Int = 0,
        estimateScale: Double = 1
    ) -> ContextPlan {
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
            String(cachedSystemPrompt.count),
            String(estimateScale),
            String(schemaTokens)
        ].joined(separator: "|")
        if let cache = planCache, cache.signature == signature {
            return cache.plan
        }

        let plan = composer.plan(
            systemPrompt: cachedSystemPrompt,
            messages: promptMessages,
            contextWindow: contextWindow,
            thresholdPercent: thresholdPercent,
            summaryTokens: summaryTokens,
            estimateScale: estimateScale,
            toolTokens: schemaTokens
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
    ///
    /// Manual is unconditional: it clears the cooldown and the strike counter and folds
    /// the whole history, because the user asked. Deciding "it already fits" from a local
    /// estimate is exactly how the command used to report success while the next request
    /// overflowed at the provider (OpenCode and Hermes both exempt the manual path).
    func compactNow() async -> String {
        guard let services else { return "**Ошибка.** База данных недоступна." }

        let provider: ProviderModel
        do {
            guard let resolved = try await activeProvider(services) else {
                return "**Ошибка.** Провайдер не подключён."
            }
            provider = resolved
        } catch {
            return "**Ошибка.** Не удалось прочитать провайдеров: \(error.localizedDescription)"
        }
        let model = provider.defaultModel ?? provider.models.first ?? ""
        guard !model.isEmpty else { return "**Ошибка.** У провайдера не выбрана модель." }

        let completed = promptMessages
        guard completed.count >= 3 else {
            return "Сжимать нечего: в истории \(completed.count) сообщений — сворачивать нечего."
        }

        compactionFailures = 0
        compactionCooldownUntil = nil
        Self.resetCompactionGuard(services: services)

        let system = await buildSystemPrompt(services: services)
        let localEstimate = TokenEstimator.tokens(in: system)
            + TokenEstimator.tokens(in: checkpointSummary)
            + completed.reduce(0) { $0 + $1.tokens }

        if await compact(completed, provider: provider, model: model, services: services) {
            let measured = await calibration.lastMeasured(providerID: provider.id, model: model)
            let providerNote = measured.map { " Провайдер в прошлый раз сообщил prompt_tokens=\($0)." } ?? ""
            return "История сжата: \(completed.count) сообщений свёрнуты в саммари. "
                + "Локальная оценка до сжатия — \(localEstimate) токенов.\(providerNote) "
                + "В базе ничего не удалено."
        }
        return "**Ошибка.** Компакция не удалась; история не тронута. "
            + "Повтори /compact или проверь провайдера."
    }
}
