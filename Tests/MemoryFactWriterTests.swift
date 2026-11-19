import XCTest
@testable import Harness

/// R35.1: an extracted fact that restates an existing one replaces it, not duplicates it.
final class MemoryFactWriterTests: XCTestCase {
    private var database: AppDatabase!
    private var memory: MemoryService!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        memory = MemoryService(database: database)
    }

    private func candidate(
        _ content: String,
        quote: String,
        area: String = "fact"
    ) -> FactExtraction.Candidate {
        FactExtraction.Candidate(content: content, quote: quote, area: area)
    }

    func testNewFactIsAdded() async throws {
        let outcome = await MemoryFactWriter().write(
            [candidate("Сервер на Ubuntu 24.04", quote: "сервер на убунту 24.04")],
            memory: memory, embeddings: nil
        )
        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.replaced, 0)
        let count = try await memory.count()
        XCTAssertEqual(count, 1)
    }

    func testRestatedFactReplacesTheOldRecord() async throws {
        let old = try await memory.add("Сервер работает на Ubuntu 22.04", area: "fact")
        let outcome = await MemoryFactWriter().write(
            [candidate("Сервер работает на Ubuntu 24.04", quote: "сервер на 24.04")],
            memory: memory, embeddings: nil
        )
        XCTAssertEqual(outcome.replaced, 1)

        let hits = try await memory.search("сервер ubuntu")
        XCTAssertTrue(hits.contains { $0.content.contains("24.04") })
        XCTAssertFalse(hits.contains { $0.id == old.id }, "старая запись выпадает из выдачи")

        let history = try await memory.item(id: old.id)
        XCTAssertEqual(history?.content, "Сервер работает на Ubuntu 22.04", "история остаётся")
    }

    func testExactRestatementIsSkipped() async throws {
        _ = try await memory.add("Сервер работает на Ubuntu 24.04", area: "fact")
        let outcome = await MemoryFactWriter().write(
            [candidate("Сервер работает на Ubuntu 24.04", quote: "сервер на 24.04")],
            memory: memory, embeddings: nil
        )
        XCTAssertEqual(outcome.skipped, 1)
        XCTAssertEqual(outcome.added, 0)
        XCTAssertEqual(outcome.replaced, 0)
    }

    func testDifferentAreasAreNotMerged() async throws {
        _ = try await memory.add("Сервер работает на Ubuntu 22.04", area: "fact")
        let outcome = await MemoryFactWriter().write(
            [candidate("Сервер работает на Ubuntu 22.04", quote: "сервер на 22.04", area: "decision")],
            memory: memory, embeddings: nil
        )
        XCTAssertEqual(outcome.added, 1)
        XCTAssertEqual(outcome.replaced, 0)
    }

    func testOutcomeAddsUp() async throws {
        _ = try await memory.add("Сервер работает на Ubuntu 22.04", area: "fact")
        let outcome = await MemoryFactWriter().write(
            [
                candidate("Сервер работает на Ubuntu 22.04", quote: "сервер на 22.04"),
                candidate("Почта живёт на Fastmail", quote: "почта на fastmail")
            ],
            memory: memory, embeddings: nil
        )
        XCTAssertEqual(
            outcome.added + outcome.replaced + outcome.skipped, 2,
            "каждый факт получает ровно один исход"
        )
    }
}
