import Foundation

/// R35.1: a fact extracted from a folded conversation replaces an older record of the
/// same fact instead of piling up next to it.
///
/// `#104` and `#107` described the same server in different words and both were read by
/// id. Here a new fact that closely matches an existing one in the same area is written
/// through `supersedes_id`, so the old row stays readable but drops out of search and
/// the prompt. An exact restatement is skipped outright.
struct MemoryFactWriter: Sendable {
    /// Higher than the "is this the same fact?" question in `memory_add` (0.35): a
    /// compaction pass has no user to ask, so it only replaces on a close match.
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
                    quoteVerified: true,
                    supersedesID: existing.first?.id
                )
                await MemoryIndexer.index(id: item.id, content: item.content, sink: embeddings)
                if existing.isEmpty { outcome.added += 1 } else { outcome.replaced += 1 }
            } catch {
                outcome.skipped += 1
            }
        }
        return outcome
    }
}
