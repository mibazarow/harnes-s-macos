import Foundation

/// S1: the parent's turn must not wait for a child.
///
/// Before this, `task` was one blocking `await`: while the child worked the whole parent
/// turn stood still. The runner keeps the background `Task`s by child id so the turn can
/// return at once, Esc can stop all of them, and S6 can bound each one by time.
actor SubagentRunner {
    private var tasks: [String: Task<Void, Never>] = [:]
    private var timers: [String: Task<Void, Never>] = [:]

    var runningIDs: [String] { tasks.keys.sorted() }

    /// Starts `work` off the current actor. `detached` on purpose: a plain `Task` here
    /// would inherit the runner's isolation and serialize every child behind one actor.
    /// `onTimeout` runs when the ceiling is hit, so the caller can mark the child
    /// interrupted with a reason instead of leaving a spinner forever.
    func start(
        id: String,
        timeout: TimeInterval = TimeInterval(Tuning.subagentTimeoutSeconds),
        onTimeout: (@Sendable () async -> Void)? = nil,
        work: @escaping @Sendable () async -> Void
    ) {
        tasks[id] = Task.detached(priority: .userInitiated) {
            await work()
        }
        guard timeout > 0 else { return }
        timers[id] = Task.detached(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            guard let self, await self.isRunning(id) else { return }
            await onTimeout?()
            await self.cancel(id)
        }
    }

    func isRunning(_ id: String) -> Bool {
        tasks[id] != nil
    }

    /// Called by the work itself, so a finished child leaves the table without a race
    /// between the task's exit and this bookkeeping.
    func finished(_ id: String) {
        tasks.removeValue(forKey: id)
        timers.removeValue(forKey: id)?.cancel()
    }

    func cancel(_ id: String) {
        timers.removeValue(forKey: id)?.cancel()
        tasks.removeValue(forKey: id)?.cancel()
    }

    /// S6: Esc stops background children too, not only the parent turn.
    func cancelAll() {
        let all = tasks.values
        let pendingTimers = timers.values
        tasks.removeAll()
        timers.removeAll()
        for task in all { task.cancel() }
        for timer in pendingTimers { timer.cancel() }
    }

    func waitForAll() async {
        let all = Array(tasks.values)
        for task in all { _ = await task.value }
    }
}
