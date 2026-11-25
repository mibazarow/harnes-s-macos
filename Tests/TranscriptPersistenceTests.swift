import XCTest
@testable import Harness

/// D1: tool traces must survive a restart, not only the live turn.
@MainActor
final class TranscriptPersistenceTests: XCTestCase {
    func testTracesSurvivePersistAndRestore() async throws {
        let database = try AppDatabase(inMemory: true)
        let history = ChatHistoryService(database: database)
        let traces = [
            ToolTrace(name: "fs_read", summary: "Прочитал 120 строк", isError: false,
                      isRunning: false, callID: "call-1", arguments: #"{"path":"a.swift"}"#,
                      originalLength: 4200),
            ToolTrace(name: "bash", summary: "exit 1: not found", isError: true,
                      isRunning: false, callID: "call-2", arguments: #"{"command":"x"}"#,
                      originalLength: 90)
        ]
        let exchanges = traces.map {
            ToolExchange(callID: $0.callID, name: $0.name, arguments: $0.arguments,
                         output: $0.summary, isError: $0.isError,
                         originalLength: $0.originalLength)
        }
        try await history.append(role: .assistant, text: "готово", reasoning: nil,
                                 exchanges: exchanges, tools: traces)
        let page = try await history.recent()
        let stored = try XCTUnwrap(page.last)
        XCTAssertEqual(stored.tools.count, 2)
        XCTAssertEqual(stored.tools[0].name, "fs_read")
        XCTAssertEqual(stored.tools[0].summary, "Прочитал 120 строк")
        XCTAssertEqual(stored.tools[0].callID, "call-1")
        XCTAssertEqual(stored.tools[0].arguments, #"{"path":"a.swift"}"#)
        XCTAssertEqual(stored.tools[0].originalLength, 4200)
        XCTAssertTrue(stored.tools[1].isError)
        XCTAssertEqual(stored.exchanges.count, 2)
    }

    func testOldRowWithoutToolsRebuildsTracesFromExchanges() async throws {
        let database = try AppDatabase(inMemory: true)
        let history = ChatHistoryService(database: database)
        let long = String(repeating: "x", count: 300)
        let exchange = ToolExchange(callID: "call-9", name: "bash",
                                    arguments: "{}", output: "first line\n\(long)",
                                    isError: false)
        try await history.append(role: .assistant, text: "шаг", reasoning: nil,
                                 exchanges: [exchange])
        try await database.queue.write { db in
            try db.execute(sql: "UPDATE messages SET tools = NULL")
        }
        let stored = try await history.recent()
        let entry = try XCTUnwrap(stored.last)
        XCTAssertTrue(entry.tools.isEmpty, "raw row has no tools")

        let restored = ChatStore.syntheticTraces(entry.exchanges)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored[0].name, "bash")
        XCTAssertEqual(restored[0].summary, "first line")
        XCTAssertFalse(restored[0].isRunning)
        XCTAssertEqual(restored[0].callID, "call-9")
    }

    func testSyntheticSummaryIsCutAtOneHundredTwentyCharacters() {
        let exchange = ToolExchange(callID: "c", name: "bash", arguments: "{}",
                                    output: String(repeating: "а", count: 300), isError: true)
        let trace = ChatStore.syntheticTraces([exchange])[0]
        XCTAssertEqual(trace.summary.count, 121)
        XCTAssertTrue(trace.summary.hasSuffix("…"))
        XCTAssertTrue(trace.isError)
    }

    func testUserRowStoresNoTools() async throws {
        let database = try AppDatabase(inMemory: true)
        let history = ChatHistoryService(database: database)
        try await history.append(role: .user, text: "привет", reasoning: nil)
        let page = try await history.recent()
        let stored = try XCTUnwrap(page.last)
        XCTAssertTrue(stored.tools.isEmpty)
    }
}
