import XCTest
@testable import Harness

final class TodoStoreTests: XCTestCase {
    private func store() throws -> TodoStore {
        TodoStore(database: try AppDatabase(inMemory: true))
    }

    func testUnknownStatusIsRejected() throws {
        let todos = try store()
        XCTAssertThrowsError(
            try todos.set([["text": "шаг", "status": "готово-почти"]])
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("готово-почти"), error.localizedDescription)
        }
    }

    func testStatusAliasesTrimAndLowercase() throws {
        let todos = try store()
        try todos.set([
            ["text": "a", "status": " DONE "],
            ["text": "b", "status": "готово"],
            ["text": "c", "status": "In-Progress"]
        ])
        XCTAssertEqual(todos.items.map(\.status), ["done", "done", "active"])
    }

    func testOnlyOneStepStaysActive() throws {
        let todos = try store()
        let outcome = try todos.set([
            ["text": "первый", "status": "active"],
            ["text": "второй", "status": "active"]
        ])
        XCTAssertEqual(todos.items.map(\.status), ["pending", "active"])
        XCTAssertEqual(outcome.demoted, ["первый"])
    }

    func testPointUpdateAndComplete() throws {
        let todos = try store()
        try todos.set((1...3).map { ["text": "шаг \($0)", "status": "pending"] })

        try todos.update([["index": 2, "status": "done", "evidence": "тест прошёл"]])
        XCTAssertEqual(todos.items[1].status, "done")
        XCTAssertEqual(todos.items[1].evidence, "тест прошёл")
        XCTAssertTrue(todos.summary.contains("тест прошёл"), todos.summary)

        try todos.complete(indices: [3])
        XCTAssertEqual(todos.items.map(\.status), ["pending", "done", "done"])

        XCTAssertThrowsError(try todos.update([["index": 9, "status": "done"]]))
    }

    func testDoneWithoutEvidenceIsReported() throws {
        let todos = try store()
        let outcome = try todos.set([["text": "шаг", "status": "done"]])
        XCTAssertEqual(outcome.doneWithoutEvidence, ["шаг"])
    }

    func testPlanSurvivesUntilEverythingIsClosed() throws {
        let todos = try store()
        try todos.set([
            ["text": "сделано", "status": "done"],
            ["text": "осталось", "status": "pending"]
        ])

        todos.clearIfFinished()
        XCTAssertEqual(todos.items.count, 2, "незакрытый план переживает ход")

        todos.beginTurn()
        XCTAssertTrue(todos.summary.contains("перенесено из прошлого хода"), todos.summary)

        try todos.complete(indices: [2])
        todos.clearIfFinished()
        XCTAssertTrue(todos.items.isEmpty, "закрытый план убирается")
    }

    func testNudgeThresholdDependsOnPlanSize() throws {
        let todos = try store()
        try todos.set((1...10).map { ["text": "шаг \($0)", "status": "pending"] })
        XCTAssertEqual(todos.nudgeThreshold, 20)

        try todos.set([["text": "один", "status": "pending"]])
        XCTAssertEqual(todos.nudgeThreshold, 4)
    }
}
