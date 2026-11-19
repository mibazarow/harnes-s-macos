import Foundation

/// Priors for retrieval, not for the injected prompt block.
///
/// Relevance alone treats a record fetched every day and one nobody touched for a year
/// as equals. Three cheap signals fix that, multiplied rather than added so a weak
/// match cannot be rescued by age or frequency:
///
/// ```
/// score = relevance * recency * frequency * importance
/// ```
///
/// B12: the shape is taken from a system that ran it on ten thousand events. Two
/// details matter. A question about the past ("когда", "раньше", "помнишь") switches the
/// recency penalty off — there is no point punishing age when age is what was asked
/// for. And the decay is `0.985^days` (half weight in ~46 days), not `0.5^(days/30)`,
/// which buried a month-old record.
///
/// The prompt block deliberately stays ordered by area and id: reordering it on every
/// touch would break the provider's prefix cache (M37, P34).
enum MemoryRanker {
    /// Daily decay factor. Half the weight after ~46 days.
    static let dailyDecay: Double = 0.985
    static let frequencyStep: Double = 0.1
    /// Ten thousand reads must not make a record immortal.
    static let frequencyCap: Double = 5.0

    /// Words that mean the question is about the past.
    static let pastMarkers: [String] = [
        "давно", "помниш", "раньше", "когда", "истори", "было", "прошл", "вчера",
        "remember", "earlier", "previously", "history", "last time"
    ]

    static func isPastQuestion(_ query: String) -> Bool {
        let lower = query.lowercased()
        return pastMarkers.contains { lower.contains($0) }
    }

    /// 1.0 for "just used", 0.985^days afterwards. A question about the past gets no
    /// penalty at all.
    static func recency(lastUsed: Date?, now: Date, isPastQuestion: Bool = false) -> Double {
        if isPastQuestion { return 1 }
        guard let lastUsed else { return 0 }
        let days = max(now.timeIntervalSince(lastUsed) / 86_400, 0)
        return pow(dailyDecay, days)
    }

    /// `1 + 0.1 * hits`, capped. The tenth read matters as much as the first, but a
    /// record cannot buy its way past a better match forever.
    static func frequency(hits: Int) -> Double {
        min(1 + frequencyStep * Double(max(hits, 0)), frequencyCap)
    }

    /// 0.5 for a record explicitly marked worthless, 1 otherwise. Anything above 1 is
    /// reserved for a future manual ranking.
    static func importanceFactor(_ value: Int) -> Double {
        value <= 0 ? 0.5 : 1
    }

    static func score(
        relevance: Double,
        hits: Int,
        lastUsed: Date?,
        now: Date,
        importance: Int = 1,
        isPastQuestion: Bool = false
    ) -> Double {
        max(relevance, 0)
            * recency(lastUsed: lastUsed, now: now, isPastQuestion: isPastQuestion)
            * frequency(hits: hits)
            * importanceFactor(importance)
    }

    /// FTS5 bm25 is negative and unbounded; `|bm25| / (1 + |bm25|)` keeps the order and
    /// puts it in the 0…1 range the multipliers expect.
    static func relevance(bm25: Double?) -> Double {
        guard let bm25 else { return 0 }
        let strength = max(-bm25, 0)
        return strength / (1 + strength)
    }
}
