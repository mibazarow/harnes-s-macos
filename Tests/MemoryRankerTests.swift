import XCTest
@testable import Harness

/// B12: relevance first, then decay, frequency and importance as multipliers.
final class MemoryRankerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecencyFollowsTheDailyDecay() {
        XCTAssertEqual(MemoryRanker.recency(lastUsed: now, now: now), 1, accuracy: 0.0001)
        let month = now.addingTimeInterval(-30 * 86_400)
        XCTAssertEqual(
            MemoryRanker.recency(lastUsed: month, now: now),
            pow(0.985, 30), accuracy: 0.0001
        )
        // Half the weight after about 46 days, not after 30.
        XCTAssertGreaterThan(MemoryRanker.recency(lastUsed: month, now: now), 0.5)
        let halfLife = now.addingTimeInterval(-46 * 86_400)
        XCTAssertEqual(MemoryRanker.recency(lastUsed: halfLife, now: now), 0.5, accuracy: 0.02)
        XCTAssertEqual(MemoryRanker.recency(lastUsed: nil, now: now), 0)
    }

    func testQuestionAboutThePastHasNoDecay() {
        XCTAssertTrue(MemoryRanker.isPastQuestion("когда мы выкладывали релиз?"))
        XCTAssertTrue(MemoryRanker.isPastQuestion("помнишь, что было раньше"))
        XCTAssertFalse(MemoryRanker.isPastQuestion("собери релиз"))

        let year = now.addingTimeInterval(-365 * 86_400)
        XCTAssertEqual(
            MemoryRanker.recency(lastUsed: year, now: now, isPastQuestion: true), 1
        )
        let stale = MemoryRanker.score(
            relevance: 0.5, hits: 0, lastUsed: year, now: now, isPastQuestion: true
        )
        let stalePenalised = MemoryRanker.score(
            relevance: 0.5, hits: 0, lastUsed: year, now: now
        )
        XCTAssertGreaterThan(stale, stalePenalised)
    }

    func testFrequencyIsLinearAndCapped() {
        XCTAssertEqual(MemoryRanker.frequency(hits: 0), 1)
        XCTAssertEqual(MemoryRanker.frequency(hits: 3), 1.3, accuracy: 0.0001)
        XCTAssertEqual(MemoryRanker.frequency(hits: 10_000), MemoryRanker.frequencyCap)
    }

    func testWorthlessRecordScoresLower() {
        XCTAssertLessThan(
            MemoryRanker.score(relevance: 0.5, hits: 0, lastUsed: now, now: now, importance: 0),
            MemoryRanker.score(relevance: 0.5, hits: 0, lastUsed: now, now: now, importance: 1)
        )
    }

    func testFreshBeatsOldAtEqualRelevance() {
        let old = now.addingTimeInterval(-365 * 86_400)
        let fresh = MemoryRanker.score(relevance: 0.5, hits: 0, lastUsed: now, now: now)
        let stale = MemoryRanker.score(relevance: 0.5, hits: 0, lastUsed: old, now: now)
        XCTAssertGreaterThan(fresh, stale)
    }

    func testFrequencyCannotBeatAnExactMatch() {
        // A record with no date at all scores zero: in real data `createdAt` always
        // exists, so the comparison uses a dated record.
        let exact = MemoryRanker.score(relevance: 0.9, hits: 0, lastUsed: now, now: now)
        let frequent = MemoryRanker.score(relevance: 0.1, hits: 10_000, lastUsed: now, now: now)
        XCTAssertGreaterThan(exact, frequent)
    }

    func testFrequentRecordRanksAboveAnUntouchedTie() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)

        let used = try await memory.add("Сервер альфа")
        _ = try await memory.add("Сервер бета")
        for _ in 0..<10 { try await memory.touch(ids: [used.id]) }

        let hits = try await memory.search("сервер")
        XCTAssertEqual(hits.first?.id, used.id, "частая запись должна обойти равную ей по тексту")
    }
}
