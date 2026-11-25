import Foundation

/// R18.8: a runaway clicker must be stopped by the gate, not by the user's patience.
/// Input tools share one budget per second; exceeding it is a refusal with the count.
final class RateLimitInterceptor: ToolInterceptor, @unchecked Sendable {
    let name = "rate_limit"
    private let limit: Int
    private let clock: @Sendable () -> Date
    private let lock = NSLock()
    private var windowStart: Date
    private var used = 0

    init(limitPerSecond: Int = 20, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.limit = max(limitPerSecond, 1)
        self.clock = clock
        self.windowStart = clock()
    }

    func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> GuardVerdict {
        guard ["mouse", "keyboard", "ui"].contains(call.name) else { return .pass }
        guard allow() else {
            return .deny(
                reason: "превышен лимит \(limit) UI-событий в секунду",
                guidance: "Подожди секунду или объедини действия; серия кликов означает, "
                    + "что предыдущее действие не дало результата."
            )
        }
        return .pass
    }

    private func allow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = clock()
        if now.timeIntervalSince(windowStart) >= 1 {
            windowStart = now
            used = 0
        }
        used += 1
        return used <= limit
    }
}
