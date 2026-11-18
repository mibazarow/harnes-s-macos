import XCTest
@testable import Harness

/// M33: a checkpoint grows by appending, never by rebuilding what it already said.
final class SummaryBoundaryTests: XCTestCase {
    func testMergeKeepsTheFirstSummaryVerbatim() {
        let first = "## Цель\n- Первый факт"
        let merged = CompactionService.merge(
            previous: first, delta: "## Цель\n- Второй факт"
        )
        XCTAssertTrue(merged.hasPrefix(first), merged)
        XCTAssertTrue(merged.contains("Второй факт"))
    }

    func testEmptyDeltaDoesNotChangeTheSummary() {
        let first = "## Цель\n- Первый факт"
        XCTAssertEqual(CompactionService.merge(previous: first, delta: ""), first)
        XCTAssertEqual(CompactionService.merge(previous: "", delta: ""), "")
    }

    func testLimitCutsTheNewPartAndKeepsTheOldOne() {
        let old = String(repeating: "старое ", count: 3_000)
        let merged = CompactionService.merge(
            previous: old,
            delta: String(repeating: "новое ", count: 3_000),
            limit: old.count + 200
        )
        XCTAssertTrue(merged.hasPrefix(old), "старое саммари должно остаться дословным")
        XCTAssertTrue(merged.contains("дописано частично"))
    }

    func testBoundaryPersistsInItsOwnTable() async throws {
        let database = try AppDatabase(inMemory: true)
        let service = CompactionService()

        let initial = try await service.loadSummarizedUpTo(database: database)
        XCTAssertEqual(initial, 0)
        try await service.saveSummarizedUpTo(7, database: database)
        let saved = try await service.loadSummarizedUpTo(database: database)
        XCTAssertEqual(saved, 7)
        try await service.saveSummarizedUpTo(9, database: database)
        let updated = try await service.loadSummarizedUpTo(database: database)
        XCTAssertEqual(updated, 9)
    }

    func testOldCheckpointWithoutBoundaryStillDecodes() throws {
        let raw = #"{"summary":"s","covered":5,"createdAt":"2026-01-01T00:00:00Z"}"#
        let checkpoint = try JSONDecoder().decode(
            CompactionService.Checkpoint.self, from: Data(raw.utf8)
        )
        XCTAssertEqual(checkpoint.boundary, 5)
    }

    func testTwoCompactionsKeepTheFirstText() async throws {
        let server = try StubSSEServer(responses: [
            [
                #"{"choices":[{"delta":{"content":"Первый факт"}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
            ],
            [
                #"{"choices":[{"delta":{"content":"Второй факт"}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
            ]
        ])
        try server.start()
        defer { server.stop() }

        let provider = ProviderModel(
            id: "p1", name: "stub", baseURL: server.baseURL, apiKey: "k",
            models: ["m"], defaultModel: "m", contextWindow: 128_000, isDefault: true
        )
        let service = CompactionService()

        let first = try await service.summarize(
            messages: [ContextMessage(id: 0, role: "user", text: "первый шаг")],
            provider: provider,
            model: "m",
            previousSummary: nil
        )
        let second = try await service.summarize(
            messages: [ContextMessage(id: 1, role: "user", text: "второй шаг")],
            provider: provider,
            model: "m",
            previousSummary: first
        )

        XCTAssertTrue(second.contains(first), second)
        XCTAssertTrue(second.contains("Второй факт"), second)
    }

    func testEmptyDeltaReturnsPreviousWithoutACall() async throws {
        let provider = ProviderModel(
            id: "p1", name: "stub", baseURL: "http://127.0.0.1:1/v1", apiKey: "k",
            models: ["m"], defaultModel: "m", contextWindow: 128_000, isDefault: true
        )
        let result = try await CompactionService().summarize(
            messages: [], provider: provider, model: "m", previousSummary: "старое"
        )
        XCTAssertEqual(result, "старое")
    }
}
