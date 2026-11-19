import XCTest
import GRDB
@testable import Harness

/// B1: the checkpoint boundary is a message id, and it survives a restart.
///
/// It used to be a message *count* written into a field that everything read as an id.
/// On the live machine that left `summarized_up_to = 10151` while the newest message was
/// `18568`, and the boundary no longer meant anything.
@MainActor
final class SummaryBoundaryIDTests: XCTestCase {
    private var servers: [StubSSEServer] = []

    override func tearDown() {
        for server in servers { server.stop() }
        servers = []
        super.tearDown()
    }

    private func services(_ database: AppDatabase) async throws -> AppServices {
        let server = try StubSSEServer(responses: [[
            #"{"choices":[{"delta":{"content":"Цель: задача."}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        ]])
        try server.start()
        servers.append(server)
        let services = AppServices(database: database)
        _ = try await services.providers.save(ProviderModel(
            id: "p1", name: "stub", baseURL: server.baseURL, apiKey: "k",
            models: ["m"], defaultModel: "m", contextWindow: 128_000, isDefault: true
        ))
        return services
    }

    private func persist(_ messages: [ChatMessage], services: AppServices) async throws {
        for message in messages {
            try await services.history.append(
                role: message.role, text: message.text, reasoning: nil
            )
        }
    }

    func testCompactionWriteFailureKeepsConversationAcrossReload() async throws {
        let database = try AppDatabase(inMemory: true)
        let services = try await services(database)
        let chat = ChatStore(services: services)
        chat.messages = [
            ChatMessage(role: .user, text: "keep original request"),
            ChatMessage(role: .assistant, text: "keep original answer")
        ]
        try await persist(chat.messages, services: services)
        try await database.queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_summary BEFORE INSERT ON chat_state
                BEGIN SELECT RAISE(ABORT, 'checkpoint unavailable'); END
                """)
        }
        let result = await chat.compactNow()
        XCTAssertFalse(result.contains("История сжата"), result)
        let checkpoint = try await services.compaction.loadCheckpoint(database: database)
        XCTAssertNil(checkpoint)
        let restored = ChatStore(services: services)
        await restored.loadHistory()
        XCTAssertTrue(restored.messages.contains { $0.text == "keep original request" })
        XCTAssertTrue(restored.messages.contains { $0.text == "keep original answer" })
    }

    func testBoundaryIsAnIDInsideTheHistory() async throws {
        let database = try AppDatabase(inMemory: true)
        let services = try await services(database)
        let chat = ChatStore(services: services)
        chat.messages = [
            ChatMessage(role: .user, text: "первый шаг"),
            ChatMessage(role: .assistant, text: "делаю"),
            ChatMessage(role: .user, text: "второй шаг"),
            ChatMessage(role: .assistant, text: "готово")
        ]
        try await persist(chat.messages, services: services)

        let result = await chat.compactNow()
        XCTAssertTrue(result.contains("История сжата"), result)

        let boundary = try await services.compaction.loadSummarizedUpTo(database: database)
        let maxID = try await database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(id) FROM messages") ?? 0
        }
        XCTAssertGreaterThan(boundary, 0)
        XCTAssertLessThanOrEqual(boundary, maxID, "граница не может уйти за конец истории")

        let covered = try await services.compaction.loadCoveredCount(database: database)
        XCTAssertEqual(covered, 4, "счётчик остаётся счётчиком")
    }

    func testBoundaryGrowsMonotonicallyAcrossCompactions() async throws {
        let database = try AppDatabase(inMemory: true)
        let services = try await services(database)
        let chat = ChatStore(services: services)

        var previous = 0
        for round in 0..<3 {
            chat.messages = [
                ChatMessage(role: .user, text: "шаг \(round) а"),
                ChatMessage(role: .assistant, text: "ответ \(round)"),
                ChatMessage(role: .user, text: "шаг \(round) б")
            ]
            try await persist(chat.messages, services: services)
            let result = await chat.compactNow()
            XCTAssertTrue(result.contains("История сжата"), result)

            let boundary = try await services.compaction.loadSummarizedUpTo(database: database)
            XCTAssertGreaterThanOrEqual(boundary, previous)
            previous = boundary
        }
        XCTAssertGreaterThan(previous, 0)
    }

    func testRestartKeepsTheBoundaryWhereItWas() async throws {
        let database = try AppDatabase(inMemory: true)
        let services = try await services(database)

        let first = ChatStore(services: services)
        first.messages = [
            ChatMessage(role: .user, text: "старый шаг"),
            ChatMessage(role: .assistant, text: "старый ответ"),
            ChatMessage(role: .user, text: "и ещё шаг")
        ]
        try await persist(first.messages, services: services)
        let result = await first.compactNow()
        XCTAssertTrue(result.contains("История сжата"), result)
        let before = try await services.compaction.loadSummarizedUpTo(database: database)
        XCTAssertGreaterThan(before, 0)

        // A fresh store is what a relaunch creates: it reads the checkpoint back.
        let second = ChatStore(services: services)
        await second.loadHistory()
        let after = try await services.compaction.loadSummarizedUpTo(database: database)
        XCTAssertEqual(after, before, "перезапуск не сдвигает границу")
        XCTAssertNotNil(second.compactedThroughID, "граница восстановлена в истории")
    }

    func testLegacyCountIsConvertedToAnID() async throws {
        let database = try AppDatabase(inMemory: true)
        let now = Timestamps.now()
        try await database.queue.write { db in
            for text in ["раз", "два", "три"] {
                try db.execute(sql: """
                    INSERT INTO messages (role, text, created_at) VALUES ('user', ?, ?)
                    """, arguments: [text, now])
            }
        }
        let service = CompactionService()
        let boundary = try await service.boundaryID(forCovered: 2, database: database)
        let maxID = try await database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT MAX(id) FROM messages") ?? 0
        }
        XCTAssertEqual(boundary, 2, "второе сообщение по порядку вставки")
        XCTAssertLessThanOrEqual(boundary, maxID)
    }

    func testCoveredBeyondTheEndClampsToTheLastID() async throws {
        let database = try AppDatabase(inMemory: true)
        let service = CompactionService()
        try await database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO messages (role, text, created_at) VALUES ('user', 'раз', ?)
                """, arguments: [Timestamps.now()])
        }
        let boundary = try await service.boundaryID(forCovered: 999, database: database)
        XCTAssertEqual(boundary, 1)
    }
}
