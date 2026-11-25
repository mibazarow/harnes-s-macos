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
            contextWindow: window(for: provider, model: model).window,
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
            if let fresh = try? await self.resolvedMain(services) {
                resolved = (fresh.provider, fresh.model)
            } else {
                Self.logLatency("compaction: provider resolve failed, using caller's")
                resolved = (provider, model)
            }
            await self.compactIfNeeded(provider: resolved.0, model: resolved.1, services: services)
            self.compactionTask = nil
        }
    }

    /// Newest user messages from the folded range, verbatim, up to `budget` tokens.
    ///
    /// A hard fold used to drop everything below the checkpoint except the first three
    /// messages; a condition stated halfway through a long session disappeared silently.
    static func retainedUserMessages(_ messages: [ContextMessage], budget: Int) -> String {
        var picked: [String] = []
        var used = 0
        for message in messages.reversed() where message.role == "user" {
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let cost = TokenEstimator.tokens(in: text)
            if used + cost > budget, !picked.isEmpty { break }
            let clipped = cost > budget ? cutToParagraph(text, budget: budget) : text
            picked.insert(clipped, at: 0)
            used += TokenEstimator.tokens(in: clipped)
        }
        return picked.joined(separator: "\n\n")
    }

    /// Cuts at a paragraph boundary; a sentence cut loses the condition's qualifiers.
    private static func cutToParagraph(_ text: String, budget: Int) -> String {
        var result = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            let next = result.isEmpty ? paragraph : result + "\n\n" + paragraph
            if TokenEstimator.tokens(in: next) > budget { break }
            result = next
        }
        return result.isEmpty ? String(text.prefix(max(200, budget * 2))) : result
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
            guard let resolved = try? await self.resolvedMain(services) else { return }
            let provider = resolved.provider
            let model = resolved.model

            // The snapshot is taken when the boundary is recorded; by the time the task
            // runs, the history may have been cleared, restored or replaced. A stale
            // `start` then walks past the end of `messages` and traps in `compact`.
            guard let first = task.first?.id,
                  let start = self.messages.firstIndex(where: { $0.id == first }) else { return }
            let coveredIndex = self.compactedThroughID.flatMap { id in
                self.messages.firstIndex(where: { $0.id == id })
            }

            var items: [ContextMessage] = []
            for (offset, message) in task.enumerated() {
                guard start + offset < self.messages.count else { break }
                let index = start + offset
                if let coveredIndex, index <= coveredIndex { continue }
                guard message.state == .complete, message.role != .system,
                      !message.text.isEmpty || !message.exchanges.isEmpty else { continue }
                let extraTokens = message.exchanges.reduce(0) { sum, exchange in
                    sum + ToolCost.exchange(
                        name: exchange.name,
                        arguments: exchange.arguments,
                        output: exchange.output,
                        id: exchange.callID
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

    var promptMessages: [ContextMessage] { promptMessages(pruning: [:]) }

    /// The messages that go to the model, optionally with finished tool output already
    /// replaced by the stub. The plan must see the same volume the provider will.
    func promptMessages(pruning stubs: [String: String]) -> [ContextMessage] {
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
                let output = stubs[exchange.callID] ?? exchange.output
                return sum + ToolCost.exchange(
                    name: exchange.name,
                    arguments: exchange.arguments,
                    output: output,
                    id: exchange.callID
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

    /// The same request measured before tool output is stubbed. Logged as
    /// `phase=pre_prune`, so the next `prompt_breakdown` line — and the provider's
    /// `prompt_tokens` after it — can be compared against the history that was actually
    /// pruned instead of against a different state of it.
    ///
    /// `messages` here counts stored turns, not wire messages: expansion into
    /// assistant/tool pairs happens later, in `buildHistory`.
    func prePruneBreakdown(system: String, upcomingImages: Int = 0) -> PromptBreakdown {
        let all = promptMessages
        return PromptBreakdown(
            system: TokenEstimator.tokens(in: system),
            tools: schemaTokens,
            summary: TokenEstimator.tokens(in: checkpointSummary),
            history: all.reduce(0) { $0 + $1.tokens },
            images: upcomingImages,
            // B3: empty assistant rows are stored but carry no text; counting them made
            // `messages=` look twice as large as the conversation really is.
            messages: all.filter { !$0.text.isEmpty }.count,
            memory: promptMemoryCount,
            memoryTokens: promptMemoryTokens,
            phase: "pre_prune"
        )
    }

    /// One decision for "what can leave the request". Used by the window plan, the
    /// calibration and the request builder, so all three talk about the same volume.
    func plannedPruning(threshold: Int = Tuning.toolOutputPruneBatchTokens) -> ToolOutputPruner.Plan {
        ToolOutputPruner.plan(
            messages: messages,
            mode: Tuning.toolOutputPruning,
            compactionHappened: compactedInWindow || pruneAtBoundary,
            threshold: threshold,
            protectedSteps: Tuning.toolOutputPruneProtectedSteps
        )
    }

    /// D6: a cache reset is priced in the provider's tokens. A calibration that has
    /// converged scales the default with the real ratio; an unproven one keeps it.
    func pruneThreshold(provider: ProviderModel, model: String) async -> Int {
        let base = Tuning.toolOutputPruneBatchTokens
        guard let drift = await calibration.drift(
            providerID: provider.id, model: model, envelopeHash: prefixHash
        ),
              drift.withinTolerance else { return base }
        let scaled = Int(Double(base) * drift.ratio)
        return min(max(scaled, base / 2), base * 2)
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
        let summaryBefore = TokenEstimator.tokens(in: checkpointSummary)

        // R31.3: the fold is about to drop these messages. Pull durable facts out first,
        // in one bounded request; a failure here must not stop the compaction that keeps
        // the turn alive, so it is swallowed and only logged.
        await extractFactsBeforeFolding(
            contextMessages, provider: provider, model: model, services: services
        )

        do {
            // D5: start before the request, clear after the boundary is on disk. A crash
            // in between leaves the start without its end, and the next session sees it.
            try await services.compaction.beginLock(turn: messages.count, database: services.database)
            var summary = try await services.compaction.summarize(
                messages: CompactionService.summarizable(contextMessages),
                provider: provider,
                model: model,
                previousSummary: checkpointSummary.isEmpty ? nil : checkpointSummary
            )
            // User conditions stated mid-session are not always captured by a summary.
            // Keep the newest ones verbatim, within a small budget, before the checkpoint.
            let retained = Self.retainedUserMessages(
                contextMessages, budget: Tuning.retainedUserTokens
            )
            if !retained.isEmpty, !summary.contains("Условия, поставленные пользователем") {
                summary += "\n\n## Условия, поставленные пользователем по ходу работы\n" + retained
            }
            // Every mutation below is written to the database before the in-memory state
            // is touched: a throw between the two used to leave the counts ahead of what
            // was actually folded, and the boundary drifted forward on every retry.
            let coveredAfter = checkpointCovered + contextMessages.count
            let lastCompacted = contextMessages.last.flatMap { item in
                item.id >= 0 && item.id < messages.count ? messages[item.id].id : nil
            }

            // B1: the pointer is a message id, the count is a count. Writing the count
            // into the id field is what let the boundary drift past the end of the
            // history once the app restarted and rebuilt it from the wrong coordinate.
            let boundary = try await services.compaction.boundaryID(
                forCovered: coveredAfter, database: services.database
            )

            try Task.checkCancellation()
            try await services.compaction.saveCheckpoint(
                CompactionService.Checkpoint(
                    summary: summary,
                    coveredMessageCount: coveredAfter,
                    createdAt: Timestamps.now(),
                    summarizedUpTo: boundary
                ),
                database: services.database
            )

            try await services.compaction.clearLock(database: services.database)
            checkpointSummary = summary
            checkpointCovered = coveredAfter
            if let lastCompacted { compactedThroughID = lastCompacted }

            compactionFailures = 0
            compactionCooldownUntil = nil
            recordCompactionEffectiveness(
                before: beforeTokens, services: services
            )
            // B2: without this line a successful fold is invisible in the log, and the
            // next session cannot tell it apart from a fold that never ran.
            Self.logLatency(CompactionLog.ok(
                messages: contextMessages.count,
                summaryBefore: summaryBefore,
                summaryAfter: TokenEstimator.tokens(in: summary)
            ))
            return true
        } catch {
            compactionFailures += 1
            // Back off progressively: a second attempt in a minute is reasonable, a
            // tenth is just burning tokens against a broken provider.
            let seconds: TimeInterval = compactionFailures >= 3 ? 600 : 120
            compactionCooldownUntil = Date().addingTimeInterval(seconds)
            Self.logLatency(CompactionLog.failure(
                attempts: compactionFailures, reason: error.localizedDescription
            ))
            return false
        }
    }

    /// Best-effort fact extraction from the messages about to be folded (R31.3).
    /// Only user text is read, every fact must carry a verified quote, and duplicates
    /// merge into the existing record instead of piling up.
    private func extractFactsBeforeFolding(
        _ contextMessages: [ContextMessage],
        provider: ProviderModel,
        model: String,
        services: AppServices
    ) async {
        let sources = FactExtraction.userText(from: contextMessages)
        guard !sources.isEmpty else { return }

        do {
            let candidates = try await FactExtractor().extract(
                messages: contextMessages, provider: provider, model: model
            )
            guard !candidates.isEmpty else {
                Self.logLatency("facts_extracted candidates=0")
                return
            }
            // R35.1: a fact that restates an existing one replaces it through
            // supersedes_id instead of piling up beside it.
            let outcome = await MemoryFactWriter().write(
                candidates, memory: services.memory, embeddings: services.embeddings
            )
            Self.logLatency(
                "facts_extracted candidates=\(candidates.count) added=\(outcome.added) "
                + "replaced=\(outcome.replaced) skipped=\(outcome.skipped)"
            )
        } catch {
            Self.logLatency("facts_extracted failed: \(error.localizedDescription)")
        }
    }

    var compactionCoolingDown: Bool {
        guard let until = compactionCooldownUntil else { return false }
        return Date() < until
    }

    func compactIfNeeded(provider: ProviderModel, model: String, services: AppServices) async {
        let scale = await calibration.scale(providerID: provider.id, model: model, envelopeHash: prefixHash)
        let plan = contextPlan(
            contextWindow: window(for: provider, model: model).window,
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
        if compactionCoolingDown {
            // B4: the silent exit left no trace at all, so a skipped fold looked like a
            // fold that never happened.
            Self.logLatency(CompactionLog.cooldown(failures: compactionFailures))
            return
        }

        var guardState = Self.loadCompactionGuard(services: services)
        if let blocked = guardState.blockedUntil, blocked > Date() {
            Self.logLatency(CompactionLog.blocked(
                until: blocked, strikes: guardState.strikes
            ))
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
        guard let sample = await calibration.lastSample(
            providerID: provider.id, model: model, envelopeHash: prefixHash
        ) else { return }
        let usable = composer.budget(
            for: window(for: provider, model: model).window,
            thresholdPercent: compactionThreshold
        ).usable
        let all = promptMessages
        guard all.count > 4 else { return }

        // The measured number belongs to the prompt it measured. If the history has
        // changed since, the absolute value says nothing about the current one; scale
        // it by the estimator's own ratio (R15.8: 101k from a 119k prompt meant 32k
        // for the 38k prompt that was about to be sent, not 101k).
        let system = await buildSystemPrompt(services: services)
        let localEstimate = TokenEstimator.tokens(in: system)
            + TokenEstimator.tokens(in: checkpointSummary)
            + all.reduce(0) { $0 + $1.tokens }
        let effective = PromptPressure.scaledMeasured(
            measured: sample.measured, basis: sample.estimated, estimated: localEstimate
        )
        guard effective > Int(Double(usable) * 0.6) else { return }
        guard !compactionCoolingDown else { return }

        let fold = Array(all.prefix(all.count / 2))
        guard !fold.isEmpty else { return }

        if await compact(fold, provider: provider, model: model, services: services) {
            notice("История сжата заранее: \(fold.count) сообщений (\(effective) из \(usable) токенов у провайдера).")
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
            services: services,
            upcomingImages: attachments.filter { $0.kind == .image }.count
        )

        var history: [ProviderMessage] = [ProviderMessage(role: .system, content: prepared.system)]

        let stubs = prepared.stubs
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
                        ToolCall(
                            id: $0.callID,
                            name: $0.name,
                            // A pruned result and its call leave together: a stub saying
                            // "output removed" next to a two-kilobyte patch is noise.
                            arguments: stubs[$0.callID] == nil
                                ? $0.arguments
                                : ToolOutputPruner.prunedArguments
                        )
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

        // One line per request: the parts sum to `total_est`, and the next line in the
        // log is the provider's own `prompt_tokens` for the same request.
        let breakdown = PromptBreakdown(
            system: TokenEstimator.tokens(in: prepared.system),
            tools: schemaTokens,
            summary: TokenEstimator.tokens(in: checkpointSummary),
            history: prepared.included.reduce(0) { $0 + $1.tokens },
            images: images.reduce(0) { $0 + ImageCost.tokens(in: $1) },
            messages: prepared.included.filter { !$0.text.isEmpty }.count,
            memory: promptMemoryCount,
            memoryTokens: promptMemoryTokens
        )
        Self.logLatency(breakdown.line)
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

        let pruning = plannedPruning()
        let plan = composer.plan(
            systemPrompt: cachedSystemPrompt,
            messages: promptMessages(pruning: pruning.replacements),
            contextWindow: contextWindow,
            thresholdPercent: thresholdPercent,
            summaryTokens: summaryTokens,
            estimateScale: estimateScale,
            toolTokens: schemaTokens
        )
        planCache = (signature, plan)
        return plan
    }

    /// Recomputes the numbers the composer shows. Called at turn boundaries and on
    /// startup, not from `body`.
    func refreshContextUsage(contextWindow: Int) {
        let plan = contextPlan(
            contextWindow: contextWindow,
            thresholdPercent: compactionThreshold,
            summaryTokens: TokenEstimator.tokens(in: checkpointSummary),
            estimateScale: estimateScale
        )
        recordContextUsage(plan)
    }

    func recordContextUsage(_ plan: ContextPlan) {
        contextUsage = ContextUsage(
            usedTokens: plan.usedTokens,
            contextWindow: plan.contextWindow,
            compacted: plan.compacted.count,
            overThreshold: plan.isOverThreshold
        )
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
        let model: String
        do {
            guard let resolved = try await resolvedMain(services) else {
                return "**Ошибка.** Провайдер не подключён или не выбрана модель."
            }
            provider = resolved.provider
            model = resolved.model
        } catch {
            return "**Ошибка.** Не удалось прочитать провайдеров: \(error.localizedDescription)"
        }

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
            let measured = await calibration.lastMeasured(providerID: provider.id, model: model, envelopeHash: prefixHash)
            let providerNote = measured.map { " Провайдер в прошлый раз сообщил prompt_tokens=\($0)." } ?? ""
            return "История сжата: \(completed.count) сообщений свёрнуты в саммари. "
                + "Локальная оценка до сжатия — \(localEstimate) токенов.\(providerNote) "
                + "В базе ничего не удалено."
        }
        return "**Ошибка.** Компакция не удалась; история не тронута. "
            + "Повтори /compact или проверь провайдера."
    }
}
