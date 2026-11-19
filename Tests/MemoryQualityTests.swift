import XCTest
@testable import Harness

/// B11: chatter and retellings never become memory rows.
final class MemoryQualityTests: XCTestCase {
    private var database: AppDatabase!
    private var memory: MemoryService!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        memory = MemoryService(database: database)
    }

    func testAcknowledgementsAreRefused() {
        for text in ["ок", "ага", "спс", "да", "нет", "понял"] {
            XCTAssertNotNil(
                MemoryQuality.rejection(for: text, source: "chat"), "«\(text)» прошло"
            )
        }
    }

    func testShortNoiseIsRefused() {
        XCTAssertNotNil(MemoryQuality.rejection(for: "++", source: "chat"))
        XCTAssertNotNil(MemoryQuality.rejection(for: "🙂🙂", source: "chat"))
    }

    func testNormalFactPasses() {
        XCTAssertNil(MemoryQuality.rejection(
            for: "Сервер альфа крутится на Ubuntu 24.04", source: "chat"
        ))
    }

    func testCompactionRejectsRetellingPrefixes() {
        XCTAssertNotNil(MemoryQuality.rejection(
            for: "Пользователь также получил что-то из Apple ID вчера", source: "compaction"
        ))
        XCTAssertNotNil(MemoryQuality.rejection(
            for: "Говорящий упомянул сервер", source: "compaction"
        ))
    }

    func testCompactionRejectsUnstableTimeWords() {
        for text in [
            "Пользователь имеет Apple Developer Account, подписано вчера",
            "Возможно, сервер работает на Ubuntu",
            "Пользователь кажется доволен"
        ] {
            XCTAssertNotNil(
                MemoryQuality.rejection(for: text, source: "compaction"), "«\(text)» прошло"
            )
        }
    }

    func testCompactionRejectsShortFacts() {
        XCTAssertNotNil(MemoryQuality.rejection(for: "Сервер тут", source: "compaction"))
    }

    func testUserSourceIsNotHeldToTheFactRules() {
        // The user's own short statement is allowed to be a preference.
        XCTAssertNil(MemoryQuality.rejection(for: "Любит тёмную тему", source: "chat"))
    }

    func testAddRefusesAndWritesNothing() async throws {
        do {
            _ = try await memory.add("ок", source: "chat")
            XCTFail("подтверждение не должно записываться")
        } catch {
            let count = try await memory.count()
            XCTAssertEqual(count, 0)
        }
    }

    func testCompactionFactIsRefusedAtTheServiceBoundary() async throws {
        do {
            _ = try await memory.add(
                "Пользователь также получил что-то из Apple ID вчера",
                source: "compaction", quote: "получил что-то из Apple ID", quoteVerified: true
            )
            XCTFail("пересказ не должен записываться")
        } catch {
            let count = try await memory.count()
            XCTAssertEqual(count, 0)
        }
    }

    func testUsefulCompactionFactStillLands() async throws {
        let item = try await memory.add(
            "Сервер альфа работает на Ubuntu 24.04",
            source: "compaction", quote: "сервер на убунту", quoteVerified: true
        )
        XCTAssertEqual(item.content, "Сервер альфа работает на Ubuntu 24.04")
    }
}
