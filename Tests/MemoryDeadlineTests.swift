import XCTest
@testable import Harness

/// R33.4: a deadline needs a full date, so two deadlines can be compared mechanically.
final class MemoryDeadlineTests: XCTestCase {
    func testShortDeadlineIsRefused() {
        XCTAssertTrue(MemoryDeadline.needsFullDate(
            text: "Сертификат действует до 19.10", area: "fact"
        ))
    }

    func testYearWithoutFullDateIsRefused() {
        XCTAssertTrue(MemoryDeadline.needsFullDate(
            text: "Членство истекает в 2027", area: "decision"
        ))
    }

    func testFullDatePasses() {
        XCTAssertFalse(MemoryDeadline.needsFullDate(
            text: "Сертификат действует до 18.12.2027", area: "fact"
        ))
    }

    func testOtherAreasAreNotChecked() {
        XCTAssertFalse(MemoryDeadline.needsFullDate(
            text: "Держать сроки коротко до 19.10", area: "lessons"
        ))
    }

    func testVersionNumbersDoNotLookLikeDeadlines() {
        XCTAssertFalse(MemoryDeadline.needsFullDate(
            text: "Сервер работает на Ubuntu 24.04", area: "fact"
        ))
    }

    func testToolRefusesAndWritesNothing() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let registry = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            currentUserMessage: "Сертификат действует до 19.10",
            memory: memory, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = try await registry.memoryAdd([
            "text": "Сертификат действует до 19.10",
            "quote": "сертификат действует до 19.10",
            "area": "fact"
        ])
        XCTAssertTrue(result.isError, result.output)
        XCTAssertTrue(result.output.contains("дд.мм.гггг"), result.output)
        let count = try await memory.count()
        XCTAssertEqual(count, 0)
    }
}
