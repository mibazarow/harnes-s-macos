import XCTest
@testable import Harness

/// R33.1: a claim of a result without a proving command is stored unverified.
final class MemoryClaimTests: XCTestCase {
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

    func testResultClaimWithoutCommandIsUnverified() {
        XCTAssertEqual(
            MemoryClaim.check(text: "Релиз уже выложен", area: "fact", verifiedCommand: nil),
            .unverified
        )
        XCTAssertEqual(
            MemoryClaim.check(text: "Сервер работает", area: "fact", verifiedCommand: nil),
            .unverified
        )
    }

    func testCommandMakesTheClaimAFact() {
        XCTAssertEqual(
            MemoryClaim.check(
                text: "Релиз выложен", area: "fact",
                verifiedCommand: "gh release view v1.0.1"
            ),
            .ok
        )
    }

    func testLessonsAndPlainFactsAreNotClaims() {
        XCTAssertEqual(
            MemoryClaim.check(text: "Релиз уже выложен", area: "lessons", verifiedCommand: nil),
            .ok
        )
        XCTAssertEqual(
            MemoryClaim.check(text: "Пользователь любит тёмную тему", area: "preferences",
                              verifiedCommand: nil),
            .ok
        )
    }

    func testUnverifiedRecordIsSavedOutOfThePrompt() async throws {
        let tools = registry("Запомни: релиз уже выложен")
        let result = try await tools.memoryAdd([
            "text": "Релиз 1.0.1 уже выложен", "quote": "релиз уже выложен"
        ])
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("не проверено"), result.output)

        let items = try await memory.list()
        XCTAssertEqual(items.first?.importance, 0, "непроверенное не идёт в промпт")
        XCTAssertEqual(items.first?.tags, [MemoryClaim.unverifiedTag])

        let prompt = try await memory.forPrompt()
        XCTAssertFalse(prompt.contains { $0.content.contains("выложен") },
                       "непроверенная запись не должна попадать в промпт")
    }

    func testVerifiedRecordStaysTrusted() async throws {
        let tools = registry("Проверил: релиз выложен")
        let result = try await tools.memoryAdd([
            "text": "Релиз 1.0.1 выложен",
            "quote": "релиз выложен",
            "verified_command": "gh release view v1.0.1"
        ])
        XCTAssertFalse(result.isError, result.output)
        XCTAssertFalse(result.output.contains("не проверено"), result.output)

        let items = try await memory.list()
        XCTAssertEqual(items.first?.importance, 1)
    }

    func testMergingAnUnverifiedClaimDowngradesTheRecord() async throws {
        _ = try await memory.add("Релиз 1.0.1 выложен", area: "fact")
        let merged = try await memory.add(
            "Релиз 1.0.1 выложен", area: "fact", importance: 0
        )
        XCTAssertEqual(merged.importance, 0)
    }
}
