import XCTest
@testable import Harness

/// B14: `add()` merged any two records sharing half their words, so two different facts
/// with the same wording collapsed into one and the first was overwritten.
///
/// The threshold is now 0.7. The numbers below are the actual Jaccard values of the
/// tokenizer used by the rule, so the tests fail if either the score or the cutoff moves.
final class MemoryMergeThresholdTests: XCTestCase {
    private var database: AppDatabase!
    private var memory: MemoryService!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        memory = MemoryService(database: database)
    }

    private func score(_ a: String, _ b: String) -> Double {
        MemoryService.jaccard(
            MemoryService.tokenSet(a), MemoryService.tokenSet(b)
        )
    }

    func testTheCaseFromTheBugScoresBelowTheNewCutoff() {
        // "Принтер стоит на кухне" / "Сканер стоит на кухне": three shared words of
        // five, exactly 0.6 — over the old 0.5, under the new 0.7.
        let value = score("Принтер стоит на кухне", "Сканер стоит на кухне")
        XCTAssertEqual(value, 0.6, accuracy: 0.0001)
        XCTAssertGreaterThan(value, 0.5)
        XCTAssertLessThan(value, MemoryService.mergeThreshold)
    }

    func testIdenticalFactsStillMerge() async throws {
        XCTAssertEqual(
            score("Сервер X на Ubuntu", "Сервер X на Ubuntu"), 1.0, accuracy: 0.0001
        )

        let first = try await memory.add("Сервер X на Ubuntu", area: "fact")
        let second = try await memory.add("Сервер X на Ubuntu", area: "fact")

        XCTAssertEqual(first.id, second.id, "точный повтор — та же запись")
        let count = try await memory.count()
        XCTAssertEqual(count, 1)
    }

    func testTwoDifferentFactsWithSharedWordingStaySeparate() async throws {
        let printer = try await memory.add("Принтер стоит на кухне", area: "fact")
        let scanner = try await memory.add("Сканер стоит на кухне", area: "fact")

        XCTAssertNotEqual(printer.id, scanner.id, "разные факты не должны склеиваться")
        let count = try await memory.count()
        XCTAssertEqual(count, 2)

        let stored = try await memory.list()
        XCTAssertTrue(stored.contains { $0.content == "Принтер стоит на кухне" })
        XCTAssertTrue(stored.contains { $0.content == "Сканер стоит на кухне" })
    }

    func testRestatementWithADifferentNumberStaysSeparate() async throws {
        // 0.667: a changed version number is a change of fact, not a restatement. At the
        // new cutoff it stays a second row; `supersedes_id` is the way to link them.
        XCTAssertEqual(
            score("Сервер на Ubuntu 22.04", "Сервер на Ubuntu 24.04"),
            0.667, accuracy: 0.001
        )
        let old = try await memory.add("Сервер на Ubuntu 22.04", area: "fact")
        let new = try await memory.add("Сервер на Ubuntu 24.04", area: "fact")
        XCTAssertNotEqual(old.id, new.id)
        let count = try await memory.count()
        XCTAssertEqual(count, 2)
    }

    func testExplicitReplacementStillReplaces() async throws {
        let old = try await memory.add("Сервер на Ubuntu 22.04", area: "fact")
        let replacement = try await memory.add(
            "Сервер на Ubuntu 22.04", area: "fact", supersedesID: old.id
        )
        XCTAssertNotEqual(replacement.id, old.id, "замена — всегда новая строка")
    }

    func testLongRestatementStillMerges() async throws {
        // Same sentence plus one extra clause: well above the cutoff, so the duplicate
        // does not take a second line of the prompt budget.
        let value = score(
            "Сервер альфа работает на Ubuntu 24.04 и обновляется по вторникам",
            "Сервер альфа работает на Ubuntu 24.04 и обновляется по вторникам вечером"
        )
        XCTAssertGreaterThan(value, MemoryService.mergeThreshold)

        let first = try await memory.add(
            "Сервер альфа работает на Ubuntu 24.04 и обновляется по вторникам", area: "fact"
        )
        let second = try await memory.add(
            "Сервер альфа работает на Ubuntu 24.04 и обновляется по вторникам вечером",
            area: "fact"
        )
        XCTAssertEqual(first.id, second.id)
    }
}
