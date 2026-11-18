import XCTest
@testable import Harness

/// R33.2: an outdated fact is replaced, not erased. The old row stays by id.
final class MemorySupersedeTests: XCTestCase {
    func testNewFactReplacesOldInSearchButOldStaysByID() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)

        let old = try await memory.add(
            "Сервер работает на Ubuntu 22.04", area: "fact", quote: "сервер на 22.04",
            quoteVerified: true
        )
        let new = try await memory.add(
            "Сервер работает на Ubuntu 24.04", area: "fact", quote: "сервер на 24.04",
            quoteVerified: true, supersedesID: old.id
        )

        let hits = try await memory.search("сервер ubuntu")
        XCTAssertTrue(hits.contains { $0.id == new.id }, "новый факт должен находиться")
        XCTAssertFalse(hits.contains { $0.id == old.id }, "старый факт не должен выдаваться")

        let byID = try await memory.item(id: old.id)
        XCTAssertEqual(byID?.content, "Сервер работает на Ubuntu 22.04")
    }

    func testPromptCarriesOnlyTheCurrentFact() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)

        let old = try await memory.add("Встречи по средам", area: "routines", quote: "среды")
        _ = try await memory.add(
            "Встречи по четвергам", area: "routines", quote: "четверги",
            quoteVerified: true, supersedesID: old.id
        )

        let prompt = try await memory.forPrompt()
        XCTAssertTrue(prompt.contains { $0.content.contains("четвергам") })
        XCTAssertFalse(prompt.contains { $0.content.contains("средам") })
    }

    func testListHidesSupersededButCountsRows() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)

        let old = try await memory.add("Старый адрес", area: "fact", quote: "старый")
        _ = try await memory.add(
            "Новый адрес", area: "fact", quote: "новый", supersedesID: old.id
        )

        let active = try await memory.list()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.content, "Новый адрес")
        let total = try await memory.count()
        XCTAssertEqual(total, 2, "обе строки остаются на диске")
    }

    func testSupersededRecordIsNotMergedIntoTheNewOne() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)

        let old = try await memory.add("Любимый редактор Sublime Text", area: "preferences")
        let replacement = try await memory.add(
            "Любимый редактор Sublime Text", area: "preferences", supersedesID: old.id
        )
        XCTAssertNotEqual(replacement.id, old.id, "замена — новая строка, а не правка старой")
    }
}
