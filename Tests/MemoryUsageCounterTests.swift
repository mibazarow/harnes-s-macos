import XCTest
@testable import Harness

/// R32.3: a turn says in the log how often it asked the memory.
final class MemoryUsageCounterTests: XCTestCase {
    private var database: AppDatabase!
    private var memory: MemoryService!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        memory = MemoryService(database: database)
    }

    private func registry(_ counter: MemoryUsageCounter) -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: memory, embeddings: nil, secrets: nil, skills: nil, mcp: nil,
            memoryUsage: counter
        )
    }

    func testCounterStartsAtZero() {
        let counts = MemoryUsageCounter().snapshot
        XCTAssertEqual(counts.calls, 0)
        XCTAssertEqual(counts.hits, 0)
    }

    func testSearchCountsCallAndHits() async throws {
        _ = try await memory.add("Сервер работает на Ubuntu", area: "fact")
        let counter = MemoryUsageCounter()
        _ = try await registry(counter).memorySearch(["query": "ubuntu"])

        let counts = counter.snapshot
        XCTAssertEqual(counts.calls, 1)
        XCTAssertEqual(counts.hits, 1)
    }

    func testEmptyOverviewCountsTheCall() async throws {
        let counter = MemoryUsageCounter()
        _ = try await registry(counter).memorySearch([:])
        XCTAssertEqual(counter.snapshot.calls, 1)
        XCTAssertEqual(counter.snapshot.hits, 0)
    }

    func testLineHasBothNumbers() {
        XCTAssertEqual(
            MemoryUsageCounter.logLine(calls: 3, hits: 7),
            "memory_hits=7 memory_search_calls=3"
        )
    }
}
