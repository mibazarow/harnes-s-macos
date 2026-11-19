import XCTest
@testable import Harness

/// B8: a failed call must say why, and a retried write must not double up.
final class ActionErrorTests: XCTestCase {
    private func draft(tool: String, outcome: String, error: String? = nil) -> ActionJournal.Draft {
        ActionJournal.Draft(
            sessionID: "s", messageID: "m", step: 1, tool: tool, args: "{}",
            outcome: outcome, model: "model", promptTokens: 0, completionTokens: 0,
            costUSD: 0, becauseKind: "message", becauseQuote: "", error: error
        )
    }

    func testErrorTextSurvivesTheRoundTrip() async throws {
        let database = try AppDatabase(inMemory: true)
        let journal = ActionJournal(database: database)
        _ = try await journal.record(draft(
            tool: "memory_add", outcome: "failed", error: "memory_add требует цитату"
        ))

        let rows = try await journal.list(limit: 5)
        XCTAssertEqual(rows.first?.error, "memory_add требует цитату")
    }

    func testSuccessHasNoErrorText() async throws {
        let database = try AppDatabase(inMemory: true)
        let journal = ActionJournal(database: database)
        _ = try await journal.record(draft(tool: "fs_read", outcome: "done"))

        let rows = try await journal.list(limit: 5)
        XCTAssertEqual(rows.first?.error, "")
    }

    func testLongErrorIsCut() async throws {
        let database = try AppDatabase(inMemory: true)
        let journal = ActionJournal(database: database)
        _ = try await journal.record(draft(
            tool: "bash", outcome: "failed", error: String(repeating: "я", count: 2_000)
        ))
        let rows = try await journal.list(limit: 5)
        XCTAssertEqual(rows.first?.error.count, 500)
    }
}

/// B8: the retry path of `memory_add`.
@MainActor
final class MemoryAddRetryTests: XCTestCase {
    private var database: AppDatabase!
    private var memory: MemoryService!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        memory = MemoryService(database: database)
    }

    private func registry(_ userMessage: String) -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            currentUserMessage: userMessage,
            memory: memory, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testSecondIdenticalReplacementIsNotWrittenAgain() async throws {
        let old = try await memory.add("Сервер на Ubuntu 22.04", area: "fact")
        let tools = registry("Сервер теперь на Ubuntu 24.04")
        let args: [String: Any] = [
            "text": "Сервер на Ubuntu 24.04",
            "quote": "сервер теперь на ubuntu 24.04",
            "area": "fact",
            "supersedes_id": old.id
        ]

        let first = try await tools.memoryAdd(args)
        XCTAssertTrue(first.output.contains("Заменил"), first.output)

        let second = try await tools.memoryAdd(args)
        XCTAssertTrue(second.output.contains("Уже записано"), second.output)
        let count = try await memory.count()
        XCTAssertEqual(count, 2, "старая и новая, без третьей копии")
    }

    func testDifferentTextStillWrites() async throws {
        let old = try await memory.add("Сервер на Ubuntu 22.04", area: "fact")
        let tools = registry("Сервер теперь на Ubuntu 24.04, сервер переехал")
        _ = try await tools.memoryAdd([
            "text": "Сервер на Ubuntu 24.04",
            "quote": "сервер теперь на ubuntu 24.04",
            "area": "fact",
            "supersedes_id": old.id
        ])
        let other = try await tools.memoryAdd([
            "text": "Сервер переехал в другой дата-центр",
            "quote": "сервер переехал",
            "area": "fact",
            "supersedes_id": old.id
        ])
        XCTAssertTrue(other.output.contains("Заменил"), other.output)
    }
}
