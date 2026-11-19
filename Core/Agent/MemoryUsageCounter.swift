import Foundation

/// R32.3: how much the turn actually asked the memory.
///
/// Without this number there is no way to tell "the agent remembered" from "the agent
/// answered from general knowledge and happened to be right". One line per turn in
/// `latency.log` is enough to see whether memory is used at all.
final class MemoryUsageCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var hits = 0

    func recordCall() {
        lock.lock(); defer { lock.unlock() }
        calls += 1
    }

    func recordHits(_ count: Int) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        hits += count
    }

    var snapshot: (calls: Int, hits: Int) {
        lock.lock(); defer { lock.unlock() }
        return (calls, hits)
    }

    /// The log line, kept here so the format and the numbers cannot drift apart.
    static func logLine(calls: Int, hits: Int) -> String {
        "memory_hits=\(hits) memory_search_calls=\(calls)"
    }
}
