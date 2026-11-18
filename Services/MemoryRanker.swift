import Foundation

/// Priors for retrieval, not for the injected prompt block.
///
/// Relevance alone treats a record fetched every day and one nobody touched for a year
/// as equals. Two cheap signals fix that: exponential recency and logarithmic access
/// frequency. Both are bounded on purpose — an old, heavily used record must not
/// outrank an exact match forever. The prompt block deliberately stays ordered by
/// area and id: reordering it on every touch would break the provider's prefix cache
/// (M37, P34).
enum MemoryRanker {
    /// Half-life of the recency bonus. A month-old record still counts, a year-old one
    /// is effectively gone.
    static let recencyHalfLifeDays: Double = 30
    static let recencyBonusMax: Double = 0.08
    static let accessBonusPerHit: Double = 0.02
    static let accessBonusMax: Double = 0.08

    /// 1.0 for "just used", 0.5 after one half-life, approaching zero with age.
    static func recency(lastUsed: Date?, now: Date) -> Double {
        guard let lastUsed else { return 0 }
        let days = max(now.timeIntervalSince(lastUsed) / 86_400, 0)
        return pow(0.5, days / recencyHalfLifeDays)
    }

    /// Logarithmic so the tenth hit matters less than the first; capped so frequency
    /// cannot beat a better match.
    static func access(hits: Int) -> Double {
        min(log1p(Double(max(hits, 0))) * accessBonusPerHit, accessBonusMax)
    }

    static func score(relevance: Double, hits: Int, lastUsed: Date?, now: Date) -> Double {
        relevance
            + recency(lastUsed: lastUsed, now: now) * recencyBonusMax
            + access(hits: hits)
    }

    /// FTS5 bm25 is negative and unbounded; `|bm25| / (1 + |bm25|)` keeps the order and
    /// puts it in the same 0…1 range as the bonuses, so equal bm25 stays equal and a
    /// prior can break the tie.
    static func relevance(bm25: Double?) -> Double {
        guard let bm25 else { return 0 }
        let strength = max(-bm25, 0)
        return strength / (1 + strength)
    }
}
