import XCTest
@testable import Harness

final class SchedulerTests: XCTestCase {
    func testAddListRemove() async throws {
        let database = try AppDatabase()
        let scheduler = SchedulerService(database: database)
        try scheduler.bootstrap()

        let task = try scheduler.add(title: "Проверка сайта", prompt: "Проверь example.com", intervalMinutes: 5)
        XCTAssertEqual(task.title, "Проверка сайта")

        let list = try scheduler.list()
        XCTAssertEqual(list.count, 1)

        try scheduler.setEnabled(id: task.id, enabled: false)
        XCTAssertEqual(try scheduler.list().first?.enabled, false)

        try scheduler.remove(id: task.id)
        XCTAssertTrue(try scheduler.list().isEmpty)
    }

    func testDueOnlyReturnsOverdue() async throws {
        let database = try AppDatabase()
        let scheduler = SchedulerService(database: database)
        try scheduler.bootstrap()

        _ = try scheduler.add(title: "later", prompt: "x", intervalMinutes: 60)
        XCTAssertTrue(try scheduler.due().isEmpty)

        let task = try scheduler.list()[0]
        try scheduler.markRun(task, result: "ok")
        XCTAssertTrue(try scheduler.due().isEmpty)
    }

    func testChunkingSplitsLongText() {
        let long = String(repeating: "а", count: 5_000)
        let chunks = WorkspaceIndexer.chunk(long, size: 1_000)
        XCTAssertGreaterThan(chunks.count, 3)
        XCTAssertTrue(chunks.allSatisfy { $0.count <= 1_100 })
    }

    func testChunkingSkipsTinyText() {
        XCTAssertTrue(WorkspaceIndexer.chunk("Привет", size: 1_000).isEmpty)
    }
}