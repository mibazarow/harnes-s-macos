import Foundation
import GRDB

/// Running token and money totals for the local install.
///
/// Totals live in `app_state`, so they survive a restart, and they are the only way to
/// answer "how much have I spent" — providers bill per request and never send a running
/// total.
actor UsageService {
    struct Totals: Sendable, Equatable {
        var promptTokens = 0
        var completionTokens = 0
        var cachedTokens = 0
        var cost = 0.0
    }

    private let database: AppDatabase
    private var cache: Totals?

    init(database: AppDatabase) {
        self.database = database
    }

    func totals() -> Totals {
        if let cache { return cache }
        let loaded: Totals = (try? database.queue.read { db -> Totals in
            Totals(
                promptTokens: Self.int(db, "usage.prompt_tokens"),
                completionTokens: Self.int(db, "usage.completion_tokens"),
                cachedTokens: Self.int(db, "usage.cached_tokens"),
                cost: Self.double(db, "usage.cost")
            )
        }) ?? Totals()
        cache = loaded
        return loaded
    }

    /// Adds one request. `cost` is nil when the provider has no prices configured.
    @discardableResult
    func add(
        promptTokens: Int,
        completionTokens: Int,
        cachedTokens: Int,
        cost: Double?
    ) -> Totals {
        var current = totals()
        current.promptTokens += max(promptTokens, 0)
        current.completionTokens += max(completionTokens, 0)
        current.cachedTokens += max(cachedTokens, 0)
        current.cost += max(cost ?? 0, 0)
        cache = current

        let snapshot = current
        try? database.queue.write { db in
            Self.set(db, "usage.prompt_tokens", String(snapshot.promptTokens))
            Self.set(db, "usage.completion_tokens", String(snapshot.completionTokens))
            Self.set(db, "usage.cached_tokens", String(snapshot.cachedTokens))
            Self.set(db, "usage.cost", String(snapshot.cost))
        }
        return current
    }

    /// Cost of one request in the provider's currency, or nil when no price is set.
    ///
    /// Prices are per million tokens. Cached prompt tokens are charged at the input
    /// price too: providers discount them differently and guessing a discount would
    /// make the number wrong in a way nobody can check.
    static func cost(
        promptTokens: Int,
        completionTokens: Int,
        inputPrice: Double?,
        outputPrice: Double?
    ) -> Double? {
        guard inputPrice != nil || outputPrice != nil else { return nil }
        let input = Double(max(promptTokens, 0)) * (inputPrice ?? 0) / 1_000_000
        let output = Double(max(completionTokens, 0)) * (outputPrice ?? 0) / 1_000_000
        return input + output
    }

    // MARK: - app_state helpers

    private static func int(_ db: Database, _ key: String) -> Int {
        guard let raw = try? String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?", arguments: [key]) else {
            return 0
        }
        return Int(raw) ?? 0
    }

    private static func double(_ db: Database, _ key: String) -> Double {
        guard let raw = try? String.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = ?", arguments: [key]) else {
            return 0
        }
        return Double(raw) ?? 0
    }

    private static func set(_ db: Database, _ key: String, _ value: String) {
        try? db.execute(sql: """
            INSERT INTO app_state (key, value) VALUES (?, ?)
            ON CONFLICT(key) DO UPDATE SET value = excluded.value
            """, arguments: [key, value])
    }
}