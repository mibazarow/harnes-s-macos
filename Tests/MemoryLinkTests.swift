import XCTest
@testable import Harness

/// R33.1: a query about a person surfaces facts linked to that person, even without a
/// word in common, and a link never outranks a direct match.
final class MemoryLinkTests: XCTestCase {
    func testPersonNameIsTheLongestCapitalisedWord() {
        XCTAssertEqual(MemoryService.personName("Миха — владелец этого мака"), "Миха")
        XCTAssertEqual(MemoryService.personName("Сергей Иванов"), "Сергей")
        XCTAssertNil(MemoryService.personName("просто заметка без имени"))
    }

    func testFactNamingAPersonIsLinkedAutomatically() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)

        let person = try await memory.add("Миха", area: "people", quote: "это Миха")
        let fact = try await memory.add("Миха любит тёмную тему в редакторе")

        let neighbours = await memory.neighbours(of: [person.id])
        XCTAssertEqual(neighbours[fact.id], person.id, "факт должен оказаться рядом с персоной")
    }

    func testQueryAboutPersonFindsLinkedFactWithoutSharedWords() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)

        let person = try await memory.add("Миха", area: "people", quote: "это Миха")
        let fact = try await memory.add("Пьёт чай без сахара")
        try await memory.link(person.id, fact.id, relation: "about")

        let hits = try await memory.search("Миха")
        XCTAssertEqual(hits.first?.id, person.id, "прямое совпадение идёт первым")

        let neighbours = await memory.neighbours(of: hits.map(\.id))
        XCTAssertEqual(neighbours[fact.id], person.id)
    }

    func testLinkWeightIsWeakerThanADirectMatch() {
        XCTAssertLessThan(HybridSearch.linkWeight, 1.0)
        XCTAssertGreaterThan(HybridSearch.linkWeight, 0)
    }

    func testLinksAreSymmetric() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let a = try await memory.add("Проект Харнес", area: "fact")
        let b = try await memory.add("Собирается через xcodebuild", area: "fact")

        try await memory.link(a.id, b.id)
        let fromA = await memory.neighbours(of: [a.id])
        let fromB = await memory.neighbours(of: [b.id])
        XCTAssertEqual(fromA[b.id], a.id)
        XCTAssertEqual(fromB[a.id], b.id)
    }

    func testUnlinkRemovesBothDirections() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let a = try await memory.add("Первая", area: "fact")
        let b = try await memory.add("Вторая", area: "fact")

        try await memory.link(a.id, b.id)
        try await memory.unlink(a.id, b.id)
        let fromA = await memory.neighbours(of: [a.id])
        XCTAssertNil(fromA[b.id])
    }

    func testSelfLinkIsIgnored() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let a = try await memory.add("Одна запись", area: "fact")
        try await memory.link(a.id, a.id)
        let neighbours = await memory.neighbours(of: [a.id])
        XCTAssertTrue(neighbours.isEmpty)
    }
}
