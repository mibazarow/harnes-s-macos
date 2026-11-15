import Foundation

/// The streaming paint buffer: provider chunks land here first and reach the visible
/// bubble on a timer, so a fast provider does not dump a whole paragraph at once.
///
/// The invariant every caller must keep: `flush()` before anything that reads or closes
/// the bubble (`settle`, `finish`, `trimLoop`, `stop`). Otherwise the buffered tail is
/// silently lost, which looks like a slightly truncated answer.
extension ChatStore {
    func append(_ chunk: String, to id: UUID) {
        pendingText.append(chunk)
        pendingID = id
        scheduleFlush()
    }

    /// Providers differ wildly in how they slice an answer: some send a character at
    /// a time, some send a paragraph. Appending each slice straight into `messages`
    /// made the bubble jump — nothing for a moment, then a whole paragraph at once.
    /// Text therefore lands in a buffer and reaches `messages` on a timer that is fast
    /// enough not to delay the answer and slow enough that the eye sees a flow.
    ///
    /// The interval is a ceiling, not a sleep: a provider that streams slowly still
    /// paints immediately, because the flush is scheduled on arrival and fires at once
    /// once the buffer is old enough.
    func scheduleFlush() {
        flushDeadline = Date().addingTimeInterval(Tuning.paintInterval)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            // `@MainActor` is re-acquired after every await, so the buffer is only
            // touched on the main actor.
            while let self, !self.pendingText.isEmpty || !self.pendingReasoning.isEmpty {
                let wait = self.flushDeadline.timeIntervalSinceNow
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                }
                guard !Task.isCancelled else { return }
                self.flush()
            }
            self?.flushTask = nil
        }
    }

    /// Moves the buffer into the visible bubble. Called by the timer above and, more
    /// importantly, by every code path that reads or finishes the answer.
    func flush() {
        flushText()
        flushReasoning()
    }

    private func flushText() {
        guard !pendingText.isEmpty else { return }
        let chunk = String(pendingText)
        pendingText = ""
        guard let index = messages.firstIndex(where: { $0.id == pendingID }) else { return }
        messages[index].text += chunk
    }

    private func flushReasoning() {
        guard !pendingReasoning.isEmpty else { return }
        let chunk = String(pendingReasoning)
        pendingReasoning = ""
        guard let index = messages.firstIndex(where: { $0.id == pendingReasoningID }) else { return }
        messages[index].reasoning = (messages[index].reasoning ?? "") + chunk
    }

    func messageText(of id: UUID) -> String {
        let settled = messages.first(where: { $0.id == id })?.text ?? ""
        // The buffer is part of the answer even though it is not painted yet: the
        // repetition check must see the whole text, not a stale prefix.
        guard id == pendingID, !pendingText.isEmpty else { return settled }
        return settled + pendingText
    }

    func reasoningText(of id: UUID) -> String {
        let settled = messages.first(where: { $0.id == id })?.reasoning ?? ""
        guard id == pendingReasoningID, !pendingReasoning.isEmpty else { return settled }
        return settled + pendingReasoning
    }

    /// Drops the repeating tail so the user is left with the part that made sense.
    func trimLoop(_ id: UUID) {
        // Trim the whole answer, buffer included, then stop the timer so nothing
        // arrives after the repair.
        flush()
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].text = RepetitionGuard.trimmed(messages[index].text)
        if let reasoning = messages[index].reasoning {
            messages[index].reasoning = RepetitionGuard.trimmed(reasoning)
        }
    }

    func markTruncationWarning(_ id: UUID, reason: String) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        let text = reason.lowercased() == "content_filter"
            ? "Провайдер остановил ответ по своему фильтру содержимого. Продолжение с этого места невозможно."
            : """
            Ответ обрезан по лимиту вывода провайдера, а не закончен. Продолжить с этого             места нельзя: следующий запрос начнётся заново. Попроси разбить задачу на части             или скажи «продолжи» — тогда я перескажу сделанное и пойду дальше.
            """
        messages[index].warning = text
    }

    func markLoopWarning(_ id: UUID) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].warning = """
        Остановился: ответ начал повторяться. Модель зациклилась на одном и том же,         и продолжение только тратило бы токены. Хвост повтора я убрал — переформулируй         задачу или разбей её на части.
        """
    }

    /// Same contract as `append`: the chunk is visible through `reasoningText` at once,
    /// but reaches `messages` on the paint timer, so the transcript is not republished
    /// per token.
    func appendReasoning(_ chunk: String, to id: UUID) {
        pendingReasoning.append(chunk)
        pendingReasoningID = id
        scheduleFlush()
    }

}
