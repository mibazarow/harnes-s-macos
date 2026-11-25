import Foundation

/// S1: the parent's turn must not wait for a child.
///
/// Before this, `task` was one blocking `await`: while the child worked the whole parent
/// turn stood still. The runner keeps the background `Task`s by child id so the turn can
/// return at once, Esc can stop all of them, and S6 can bound each one by time.
actor SubagentRunner {
    private var tasks: [String: Task<Void, Never>] = [:]

    var runningIDs: [String] { tasks.keys.sorted() }

    /// Starts `work` off the current actor. `detached` on purpose: a plain `Task` here
    /// would inherit the runner's isolation and serialize every child behind one actor.
    func start(id: String, work: @escaping @Sendable () async -> Void) {
        tasks[id] = Task.detached(priority: .userInitiated) {
            await work()
        }
    }

    /// Called by the work itself, so a finished child leaves the table without a race
    /// between the task's exit and this bookkeeping.
    func finished(_ id: String) {
        tasks.removeValue(forKey: id)
    }

    func cancel(_ id: String) {
        tasks.removeValue(forKey: id)?.cancel()
    }

    /// S6: Esc stops background children too, not only the parent turn.
    func cancelAll() {
        let all = tasks.values
        tasks.removeAll()
        for task in all { task.cancel() }
    }

    func waitForAll() async {
        let all = Array(tasks.values)
        for task in all { _ = await task.value }
    }
}
