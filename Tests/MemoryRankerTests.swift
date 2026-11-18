import XCTest
@testable import Harness

/// P34: relevance is the main signal; recency and access only break ties, with a cap
/// that keeps frequency from beating a better match.
final class MemoryRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecencyHalvesAtTheHalfLife() {
        XCTAssertEqual(MemoryRanker.recency(lastUsed: now, now: now), 1, accuracy: 0.0001)
        let half = now.addingTimeInterval(-MemoryRanker.recencyHalfLifeDays * 86_400)
        XCTAssertEqual(MemoryRanker.recency(lastUsed: half, now: now), 0.5, accuracy: 0.001)
        let year = now.addingTimeInterval(-365 * 86_400)
        XCTAssertLessThan(MemoryRanker.recency(lastUsed: year, now: now), 0.001)
        XCTAssertEqual(MemoryRanker.recency(lastUsed: nil, now: now), 0)
    }

    func testAccessIsLogarithmicAndCapped() {
        XCTAssertGreaterThan(MemoryRanker.access(hits: 10), MemoryRanker.access(hits: 1))
        XCTAssertEqual(
            MemoryRanker.access(hits: 1_000_000), MemoryRanker.accessBonusMax, accuracy: 0.0001
        )
    }

    func testFreshBeatsOldAtEqualRelevance() {
        let old = now.addingTimeInterval(-365 * 86_400)
        let fresh = MemoryRanker.score(relevance: 0.5, hits: 0, lastUsed: now, now: now)
        let stale = MemoryRanker.score(relevance: 0.5, hits: 0, lastUsed: old, now: now)
        XCTAssertGreaterThan(fresh, stale)
    }

    func testFrequencyCannotBeatAnExactMatch() {
        let exact = MemoryRanker.score(relevance: 0.9, hits: 0, lastUsed: nil, now: now)
        let frequent = MemoryRanker.score(relevance: 0.1, hits: 10_000, lastUsed: now, now: now)
        XCTAssertGreaterThan(exact, frequent)
    }

    func testFrequentRecordRanksAboveAnUntouchedTie() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)

        let used = try await memory.add("Сервер альфа")
        let _ = try await memory.add("Сервер бета")
        for _ in 0..<10 { try await memory.touch(ids: [used.id]) }

        let hits = try await memory.search("сервер")
        XCTAssertEqual(hits.first?.id, used.id, "частая запись должна обойти равную ей по тексту")
    }
}
