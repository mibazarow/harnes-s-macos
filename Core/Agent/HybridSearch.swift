import Foundation

struct HybridHit: Sendable {
    let item: MemoryItem
    let score: Double
    let lexicalRank: Int?
    let semanticScore: Double?
}

/// Weighted fusion of the lexical and semantic result lists.
///
/// The old code used Reciprocal Rank Fusion with equal weights, so one good semantic
/// guess could outrank an exact word match. Here lexical keeps the majority of the
/// weight, and semantic is an addition. With no vectors at all the lexical map is
/// returned unchanged — not scaled, not reordered (P31).
enum HybridFusion {
    static let lexicalWeight = 0.7
    static let semanticWeight = 0.3

    static func fuse(
        lexical: [Int64: Double],
        semantic: [Int64: Double]
    ) -> [Int64: Double] {
        guard !semantic.isEmpty else { return lexical }
        var result = lexical.mapValues { $0 * lexicalWeight }
        for (id, score) in semantic {
            result[id, default: 0] += max(score, 0) * semanticWeight
        }
        return result
    }
}

/// Combines FTS and vector similarity.
///
/// Degrades to lexical-only when the embedding model is missing, the query cannot be
/// embedded, or no stored vector matches. The reason is logged once per search so a
/// silent fallback is visible instead of guessed (P31).
struct HybridSearch {
    /// R33.1: a linked fact is worth this share of the match that found its person.
    static let linkWeight = 0.6

    let memory: MemoryService
    let embeddings: EmbeddingsService
    var label: String = "hybrid_search"
    var log: (@Sendable (String) -> Void)? = nil

    enum Mode: String, Sendable {
        case hybrid
        case lexicalOnly = "lexical_only"
    }

    struct Outcome: Sendable {
        let hits: [HybridHit]
        let mode: Mode
        let reason: String?
    }

    static func mode(hasQueryVector: Bool, semanticCount: Int) -> (Mode, String?) {
        if !hasQueryVector { return (.lexicalOnly, "no_query_vector") }
        if semanticCount == 0 { return (.lexicalOnly, "no_vectors") }
        return (.hybrid, nil)
    }

    func search(_ query: String, limit: Int = 10) async -> [HybridHit] {
        await searchDetailed(query, limit: limit).hits
    }

    func searchDetailed(_ query: String, limit: Int = 10) async -> Outcome {
        let lexical = (try? await memory.search(query, limit: limit * 2)) ?? []

        var semantic: [(id: Int64, score: Double)] = []
        var hasQueryVector = false
        if let queryVector = await embeddings.queryVector(query) {
            hasQueryVector = true
            let matches = (try? await embeddings.bestMatches(
                refKind: "memory",
                query: queryVector.values,
                limit: limit * 2
            )) ?? []
            semantic = matches.compactMap { match in
                guard let id = Int64(match.refID) else { return nil }
                return (id, match.score)
            }
        }

        let (mode, reason) = Self.mode(
            hasQueryVector: hasQueryVector, semanticCount: semantic.count
        )
        if mode == .lexicalOnly {
            log?("\(label) mode=\(mode.rawValue) reason=\(reason ?? "unknown") "
                + "lexical=\(lexical.count)")
        } else {
            log?("\(label) mode=hybrid lexical=\(lexical.count) semantic=\(semantic.count)")
        }

        let lexicalRank = Dictionary(uniqueKeysWithValues: lexical.enumerated().map { ($1.id, $0) })
        let lexicalScores = Dictionary(uniqueKeysWithValues: lexical.map { ($0.id, $0.score ?? 0) })
        let semanticScore = Dictionary(uniqueKeysWithValues: semantic.map { ($0.id, $0.score) })
        var fused = HybridFusion.fuse(lexical: lexicalScores, semantic: semanticScore)

        // R33.1: a hit on a person pulls in the facts linked to that person, even when
        // the query words never appear in them. The link is worth less than a direct
        // match (0.6 of the seed's score) and never outranks the record that found it.
        let peopleSeeds = lexical.filter { $0.area == "people" }
        if !peopleSeeds.isEmpty {
            let neighbours = await memory.neighbours(of: peopleSeeds.map(\.id))
            for (neighbour, seed) in neighbours {
                let bonus = (lexicalScores[seed] ?? 0) * Self.linkWeight
                if bonus > (fused[neighbour] ?? 0) { fused[neighbour] = bonus }
            }
        }

        var resolved: [Int64: MemoryItem] = Dictionary(
            uniqueKeysWithValues: lexical.map { ($0.id, $0) }
        )
        let missing = fused.keys.filter { resolved[$0] == nil }
        if !missing.isEmpty {
            resolved.merge(await memory.items(ids: Array(missing))) { first, _ in first }
        }

        let hits = fused.compactMap { id, score -> HybridHit? in
            guard let item = resolved[id] else { return nil }
            return HybridHit(
                item: item,
                score: score,
                lexicalRank: lexicalRank[id],
                semanticScore: semanticScore[id]
            )
        }
        .sorted { $0.score > $1.score }
        .prefix(limit)
        .map { $0 }

        return Outcome(hits: hits, mode: mode, reason: reason)
    }
}
