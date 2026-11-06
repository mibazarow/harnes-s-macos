import XCTest
@testable import Harness

final class StorageTests: XCTestCase {
    func testSecretsCRUD() async throws {
        let database = try AppDatabase()
        let secrets = SecretsService(database: database)

        let saved = try await secrets.save(alias: "gmail", value: "hunter2", note: "почта")
        XCTAssertEqual(saved.alias, "gmail")
        XCTAssertEqual(saved.value, "hunter2")

        let fetched = try await secrets.get(alias: "GMAIL")
        XCTAssertEqual(fetched?.value, "hunter2")

        let list = try await secrets.list()
        XCTAssertEqual(list.count, 1)

        let found = try await secrets.search("почт")
        XCTAssertEqual(found.first?.alias, "gmail")

        try await secrets.remove(alias: "gmail")
        let empty = try await secrets.list()
        XCTAssertTrue(empty.isEmpty)
    }

    func testMemoryFullTextSearch() async throws {
        let database = try AppDatabase()
        let memory = MemoryService(database: database)

        try await memory.add("Пароль от почты хранится в сейфе под алиасом mail")
        try await memory.add("Проект Харнес собирается через xcodebuild")
        try await memory.add("Любимый редактор — Sublime Text")

        let hits = try await memory.search("пароль почт")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].content.contains("Пароль"))

        let all = try await memory.list()
        XCTAssertEqual(all.count, 3)

        try await memory.delete(id: all[0].id)
        let afterDelete = try await memory.count()
        XCTAssertEqual(afterDelete, 2)
    }

    @MainActor
    func testMessageQueueing() async throws {
        let chat = ChatStore(services: nil)
        chat.send("первое")
        XCTAssertTrue(chat.isStreaming)

        chat.send("второе")
        XCTAssertEqual(chat.queuedCount, 1)

        chat.stop()
        XCTAssertEqual(chat.queuedCount, 0)
        XCTAssertFalse(chat.isStreaming)
    }

    func testChatHistoryPersists() async throws {
        let database = try AppDatabase()
        let history = ChatHistoryService(database: database)

        try await history.append(role: .user, text: "привет", reasoning: nil)
        try await history.append(role: .assistant, text: "ответ", reasoning: "думал")

        let recent = try await history.recent()
        XCTAssertEqual(recent.count, 2)
        XCTAssertEqual(recent[0].role, "user")
        XCTAssertEqual(recent[1].reasoning, "думал")
        let total = try await history.count()
        XCTAssertEqual(total, 2)
    }

    func testProvidersCRUD() async throws {
        let database = try AppDatabase()
        let providers = ProvidersService(database: database)

        let first = try await providers.save(ProviderModel(
            name: "Local",
            baseURL: "http://127.0.0.1:11434/v1",
            apiKey: "secret",
            models: ["llama3"],
            defaultModel: "llama3",
            contextWindow: 8_192
        ))
        XCTAssertTrue(first.isDefault)

        let second = try await providers.save(ProviderModel(
            name: "Cloud",
            baseURL: "https://api.example.com/v1",
            apiKey: "token",
            models: ["model-a", "model-b"],
            defaultModel: "model-a",
            contextWindow: 128_000,
            reasoningLevel: .maximum
        ))
        XCTAssertFalse(second.isDefault)

        var list = try await providers.list()
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.first?.name, "Local")
        XCTAssertEqual(list.first(where: { $0.id == second.id })?.reasoningLevel, .maximum)

        try await providers.setDefault(id: second.id)
        list = try await providers.list()
        XCTAssertEqual(list.first?.name, "Cloud")
        XCTAssertTrue(list.first?.isDefault ?? false)

        try await providers.delete(id: second.id)
        list = try await providers.list()
        XCTAssertEqual(list.count, 1)
        XCTAssertTrue(list[0].isDefault)
    }
}