import Foundation

/// Extraction has no stable subject identity: similarity alone must not hide old facts.
/// Explicit superseding remains available through the memory tools.
struct MemoryFactWriter: Sendable {
    /// Candidate lookup for detecting exact restatements, not authorizing replacement.
    var replaceThreshold: Double = 0.5

    struct Outcome: Sendable {
        var added = 0
        var replaced = 0
        var skipped = 0
    }

    func write(
        _ candidates: [FactExtraction.Candidate],
        memory: MemoryService,
        embeddings: (any MemoryEmbeddingSink)?
    ) async -> Outcome {
        var outcome = Outcome()
        for candidate in candidates {
            let kind = FactExtraction.kind(for: candidate.area)
            let existing = (try? await memory.similar(
                text: candidate.content, area: candidate.area, limit: 1,
                threshold: replaceThreshold
            )) ?? []

            if let match = existing.first {
                let normalized = MemoryService.tokenSet(match.content)
                let incoming = MemoryService.tokenSet(candidate.content)
                if normalized == incoming {
                    outcome.skipped += 1
                    continue
                }
            }

            do {
                let item = try await memory.add(
                    candidate.content,
                    kind: kind,
                    source: "compaction",
                    area: candidate.area,
                    quote: candidate.quote,
                    quoteVerified: true
                )
                await MemoryIndexer.index(id: item.id, content: item.content, sink: embeddings)
                outcome.added += 1
            } catch {
                outcome.skipped += 1
            }
        }
        return outcome
    }
}
