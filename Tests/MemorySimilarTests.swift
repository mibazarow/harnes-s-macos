import XCTest
@testable import Harness

/// R33.2: a new fact that looks like an existing one is a question, not a silent merge.
final class MemorySimilarTests: XCTestCase {
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

    func testSimilarFindsRestatementInTheSameArea() async throws {
        _ = try await memory.add("Сборка проекта идёт через xcodebuild", area: "decision")
        let found = try await memory.similar(
            text: "Сборка проекта идёт через xcodebuild", area: "decision"
        )
        XCTAssertEqual(found.count, 1)
    }

    func testSimilarIgnoresOtherAreas() async throws {
        _ = try await memory.add("Сборка проекта идёт через xcodebuild", area: "decision")
        let found = try await memory.similar(
            text: "Сборка проекта идёт через xcodebuild", area: "fact"
        )
        XCTAssertTrue(found.isEmpty)
    }

    func testRestatementAsksInsteadOfWriting() async throws {
        let first = try await memory.add(
            "Сборка проекта идёт через xcodebuild", area: "decision"
        )
        let tools = registry("Сборка проекта идёт через xcodebuild")
        let result = try await tools.memoryAdd([
            "text": "Сборка проекта идёт через xcodebuild",
            "quote": "сборка проекта идёт через xcodebuild",
            "area": "decision"
        ])

        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("Похоже на #\(first.id)"), result.output)
        XCTAssertTrue(result.output.contains("supersedes_id"), result.output)
        XCTAssertTrue(result.output.contains("ничего не записано"), result.output)

        let count = try await memory.count()
        XCTAssertEqual(count, 1, "до решения пользователя новая строка не создаётся")
    }

    func testSupersedeWritesTheReplacement() async throws {
        let first = try await memory.add(
            "Сборка проекта идёт через make", area: "decision"
        )
        let tools = registry("Сборка проекта идёт через xcodebuild")
        let result = try await tools.memoryAdd([
            "text": "Сборка проекта идёт через xcodebuild",
            "quote": "сборка проекта идёт через xcodebuild",
            "area": "decision",
            "supersedes_id": first.id
        ])
        XCTAssertFalse(result.isError, result.output)
        XCTAssertTrue(result.output.contains("Заменил #\(first.id)"), result.output)
    }

    func testUnrelatedFactIsWrittenWithoutAQuestion() async throws {
        _ = try await memory.add("Сборка проекта идёт через xcodebuild", area: "decision")
        let tools = registry("Принтер стоит на кухне")
        let result = try await tools.memoryAdd([
            "text": "Принтер стоит на кухне",
            "quote": "принтер стоит на кухне",
            "area": "fact"
        ])
        XCTAssertTrue(result.output.contains("Запомнил"), result.output)
    }
}
