import XCTest
@testable import Harness

/// M37: the stable prefix must not depend on the current turn or on the clock.
///
/// The provider caches an exact byte prefix. A memory block reordered by the user's
/// latest question changes the prefix on every turn and makes every request cold, even
/// when the system prompt and the tool catalog are otherwise untouched.
@MainActor
final class PromptStabilityTests: XCTestCase {
    func testPromptMemoryDoesNotDependOnTheTurnQuery() async throws {
        let database = try AppDatabase(inMemory: true)
        let services = AppServices(database: database)

        _ = try await services.memory.add(
            "Купить молоко и хлеб", area: "fact", quote: "запомни", quoteVerified: true
        )
        _ = try await services.memory.add(
            "Починить сервер и перезапустить ядро", area: "fact", quote: "запомни", quoteVerified: true
        )

        let milk = await ChatStore.promptMemories(services: services, query: "молоко")
        let server = await ChatStore.promptMemories(services: services, query: "сервер")

        XCTAssertEqual(
            milk.map(\.id), server.map(\.id),
            "порядок памяти в промпте не должен зависеть от вопроса этого хода"
        )
    }

    func testSystemPromptHasNoClockOrRelativeDate() {
        let text = Prompts.system
        for marker in ["Unix epoch", "milliseconds", "сегодня", "вчера", "today", "yesterday"] {
            XCTAssertFalse(
                text.localizedCaseInsensitiveContains(marker),
                "в стабильном префиксе не должно быть времени или относительной даты: \(marker)"
            )
        }
    }

    func testMemoryPromptTextCarriesNoTimestamp() {
        let item = MemoryItem(
            id: 1, scope: "user", content: "Пользователь живёт в Москве",
            kind: "fact", tags: [], createdAt: Timestamps.now(),
            pinned: false, hits: 0, lastUsedAt: Timestamps.now(), area: "fact"
        )
        let text = item.promptText
        XCTAssertFalse(text.contains("2026-"), text)
        XCTAssertNil(text.range(of: "\\b\\d{13}\\b", options: .regularExpression), text)
    }
}
