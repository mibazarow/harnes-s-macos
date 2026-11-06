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

    func testMemoryPinnedSurvivesForgetAndPrune() async throws {
        let database = try AppDatabase()
        let memory = MemoryService(database: database)

        let pinned = try await memory.add("Всегда собирать через xcodebuild", kind: "decision", pinned: true)
        let loose = try await memory.add("Разовый контекст про встречу в четверг")

        let removed = try await memory.forget(query: "Разовый контекст")
        XCTAssertEqual(removed.map(\.id), [loose.id])

        let afterForget = try await memory.list()
        XCTAssertEqual(afterForget.map(\.id), [pinned.id])
        XCTAssertTrue(afterForget[0].pinned)
        let relisted = try await memory.list()
        XCTAssertTrue(relisted.contains { $0.id == pinned.id })
    }

    func testMemoryPruneDropsUnusedButKeepsPinned() async throws {
        let database = try AppDatabase()
        let memory = MemoryService(database: database)

        let pinned = try await memory.add("Соглашение проекта: тесты перед коммитом", pinned: true)
        let used = try await memory.add("Пользователь предпочитает короткие ответы")
        let stale = try await memory.add("Случайная заметка, к которой не возвращались")
        try await memory.touch(ids: [used.id])

        let pruned = try await memory.pruneUnused(olderThanDays: -1)
        XCTAssertEqual(pruned, 1)

        let ids = Set(try await memory.list().map(\.id))
        XCTAssertTrue(ids.contains(pinned.id))
        XCTAssertTrue(ids.contains(used.id))
        XCTAssertFalse(ids.contains(stale.id))
    }

    func testMemoryForPromptPinsFirst() async throws {
        let database = try AppDatabase()
        let memory = MemoryService(database: database)

        let loose = try await memory.add("Обычная заметка")
        let pinned = try await memory.add("Железобетонный факт", pinned: true)
        try await memory.touch(ids: [loose.id])

        let prompt = try await memory.forPrompt(limit: 10)
        XCTAssertEqual(prompt.first?.id, pinned.id)
        XCTAssertEqual(prompt.last?.id, loose.id)
    }

    func testReleasedAttachmentKeepsMetadataAndDropsPayload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attach.txt")
        try "hello".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let attachment = try XCTUnwrap(ChatAttachment(url: url))
        XCTAssertFalse(attachment.data.isEmpty)

        let released = attachment.released()
        XCTAssertTrue(released.data.isEmpty)
        XCTAssertEqual(released.name, attachment.name)
        XCTAssertEqual(released.path, attachment.path)
        XCTAssertEqual(released.byteCount, attachment.byteCount)
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