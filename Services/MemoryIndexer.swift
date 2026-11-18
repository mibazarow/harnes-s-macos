import Foundation

/// R33.4: a fact saved now must be findable by meaning now.
///
/// Embeddings used to be computed only when the workspace indexer ran, so a fresh memory
/// was invisible to semantic search until the next re-index. This writes the vector at
/// save time. It is best-effort by contract: a missing model or a failed embed returns
/// false and never blocks the save.
protocol MemoryEmbeddingSink: Sendable {
    func cachedVector(hash: String) async -> EmbeddingsService.Vector?
    func embedOne(_ text: String) async -> EmbeddingsService.Vector?
    func store(id: Int64, vector: EmbeddingsService.Vector, hash: String) async
}

extension EmbeddingsService: MemoryEmbeddingSink {
    func cachedVector(hash: String) async -> Vector? {
        try? await vector(refKind: "memory", textHash: hash)
    }

    func embedOne(_ text: String) async -> Vector? {
        (try? await embed([text]))?.first
    }

    func store(id: Int64, vector: Vector, hash: String) async {
        try? await store(refKind: "memory", refID: String(id), vector: vector, textHash: hash)
    }
}

enum MemoryIndexer {
    /// Returns true when a vector was written. Never throws: the caller already saved
    /// the record and must not lose it because the embedder is unavailable.
    @discardableResult
    static func index(
        id: Int64,
        content: String,
        sink: (any MemoryEmbeddingSink)?
    ) async -> Bool {
        guard let sink else { return false }
        let hash = MemoryService.hash(content)
        if let existing = await sink.cachedVector(hash: hash) {
            await sink.store(id: id, vector: existing, hash: hash)
            return true
        }
        guard let vector = await sink.embedOne(content) else { return false }
        await sink.store(id: id, vector: vector, hash: hash)
        return true
    }
}
