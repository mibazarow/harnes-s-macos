import XCTest
@testable import Harness

/// B14/B16: `add()` merged records by word overlap, and merging overwrites `content`, so
/// a different fact was silently lost.
///
/// B14 raised the cutoff to 0.7; B16 replaced the cutoff with a structural rule, because
/// "Сервер альфа на Ubuntu 24.04" and "Сервер бета на Ubuntu 24.04" score 0.714 and are
/// two machines. Two records are the same fact only when they carry the same content
/// words.
final class MemoryMergeRuleTests: XCTestCase {
    private var database: AppDatabase!
    private var memory: MemoryService!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        memory = MemoryService(database: database)
    }

    private func score(_ a: String, _ b: String) -> Double {
        MemoryService.jaccard(MemoryService.tokenSet(a), MemoryService.tokenSet(b))
    }

    // MARK: - The case from B14

    func testTwoDifferentFactsWithSharedWordingStaySeparate() async throws {
        // Three shared words of five: 0.6, over the old 0.5 cutoff.
        XCTAssertEqual(
            score("Принтер стоит на кухне", "Сканер стоит на кухне"), 0.6, accuracy: 0.0001
        )

        let printer = try await memory.add("Принтер стоит на кухне", area: "fact")
        let scanner = try await memory.add("Сканер стоит на кухне", area: "fact")

        XCTAssertNotEqual(printer.id, scanner.id, "разные факты не должны склеиваться")
        let count = try await memory.count()
        XCTAssertEqual(count, 2)

        let stored = try await memory.list()
        XCTAssertTrue(stored.contains { $0.content == "Принтер стоит на кухне" })
        XCTAssertTrue(stored.contains { $0.content == "Сканер стоит на кухне" })
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

    // MARK: - The case from B16

    func testSameTemplateDifferentSubjectStaysSeparate() async throws {
        // 0.714: above the old 0.7 cutoff, yet two different servers.
        XCTAssertEqual(
            score("Сервер альфа на Ubuntu 24.04", "Сервер бета на Ubuntu 24.04"),
            0.714, accuracy: 0.001
        )

        let alpha = try await memory.add("Сервер альфа на Ubuntu 24.04", area: "fact")
        let beta = try await memory.add("Сервер бета на Ubuntu 24.04", area: "fact")

        XCTAssertNotEqual(alpha.id, beta.id, "разные субъекты не должны склеиваться")
        let count = try await memory.count()
        XCTAssertEqual(count, 2)
    }

    func testChangedVersionNumberStaysSeparate() async throws {
        let old = try await memory.add("Сервер на Ubuntu 22.04", area: "fact")
        let new = try await memory.add("Сервер на Ubuntu 24.04", area: "fact")
        XCTAssertNotEqual(old.id, new.id, "смена версии — новый факт, старый не стирается")
        let count = try await memory.count()
        XCTAssertEqual(count, 2)
    }

    // MARK: - What still merges

    func testWordOrderAndPrepositionsDoNotMatter() async throws {
        // Same content words, different order and preposition.
        XCTAssertEqual(
            MemoryService.contentTokens("Сервер работает на Ubuntu"),
            MemoryService.contentTokens("На Ubuntu работает сервер")
        )

        let first = try await memory.add("Сервер работает на Ubuntu", area: "fact")
        let second = try await memory.add("На Ubuntu работает сервер", area: "fact")
        XCTAssertEqual(first.id, second.id)
    }

    func testExplicitReplacementStillReplaces() async throws {
        let old = try await memory.add("Сервер на Ubuntu 22.04", area: "fact")
        let replacement = try await memory.add(
            "Сервер на Ubuntu 22.04", area: "fact", supersedesID: old.id
        )
        XCTAssertNotEqual(replacement.id, old.id, "замена — всегда новая строка")
    }

    // MARK: - The rule itself

    func testNegationIsNeverAStopword() {
        // Dropping "не" would merge "работает" with "не работает".
        XCTAssertNotEqual(
            MemoryService.contentTokens("Сервер работает"),
            MemoryService.contentTokens("Сервер не работает")
        )
        XCTAssertFalse(MemoryService.stopwords.contains("не"))
        XCTAssertFalse(MemoryService.stopwords.contains("ни"))
        XCTAssertFalse(MemoryService.stopwords.contains("нет"))
    }

    func testNegatedFactIsNotMergedIntoTheAffirmative() async throws {
        let works = try await memory.add("Сервер работает", area: "fact")
        let broken = try await memory.add("Сервер не работает", area: "fact")
        XCTAssertNotEqual(works.id, broken.id)
    }

    func testStopwordsDoNotBecomeContent() {
        XCTAssertTrue(MemoryService.contentTokens("на в и с по").isEmpty)
        XCTAssertEqual(
            MemoryService.contentTokens("Сервер на кухне"),
            ["сервер", "кухне"]
        )
    }
}
