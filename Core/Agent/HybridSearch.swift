import Foundation

struct HybridHit: Sendable {
    let item: MemoryItem
    let score: Double
    let lexicalRank: Int?
    let semanticScore: Double?
}

/// Combines FTS and vector similarity with Reciprocal Rank Fusion.
/// Degrades to lexical-only when embeddings are unavailable.
struct HybridSearch {
    let memory: MemoryService
    let embeddings: EmbeddingsService

    func search(_ query: String, limit: Int = 10) async -> [HybridHit] {
        let lexical = (try? await memory.search(query, limit: limit * 2)) ?? []

        var semantic: [(id: Int64, score: Double)] = []
        if let queryVector = await embeddings.queryVector(query) {
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

        let semanticRank = Dictionary(uniqueKeysWithValues: semantic.enumerated().map { ($1.id, $0) })
        let semanticScore = Dictionary(uniqueKeysWithValues: semantic.map { ($0.id, $0.score) })
        let lexicalRank = Dictionary(uniqueKeysWithValues: lexical.enumerated().map { ($1.id, $0) })
        let lexicalByID = Dictionary(uniqueKeysWithValues: lexical.map { ($0.id, $0) })

        var ids = Set(lexicalByID.keys)
        ids.formUnion(semanticScore.keys)

        let k = 60.0
        var results: [HybridHit] = []

        var resolved: [Int64: MemoryItem] = lexicalByID
        let missing = Array(ids).filter { resolved[$0] == nil }
        if !missing.isEmpty {
            resolved.merge(await memory.items(ids: missing)) { first, _ in first }
        }

        for id in ids {
            guard let item = resolved[id] else { continue }
            var rrf = 0.0
            if let rank = lexicalRank[id] { rrf += 1.0 / (k + Double(rank + 1)) }
            if let rank = semanticRank[id] { rrf += 1.0 / (k + Double(rank + 1)) }
            results.append(HybridHit(
                item: item,
                score: rrf,
                lexicalRank: lexicalRank[id],
                semanticScore: semanticScore[id]
            ))
        }

        return results.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }
}
