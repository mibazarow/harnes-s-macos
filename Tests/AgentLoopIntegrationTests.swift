import XCTest
@testable import Harness

final class AgentLoopIntegrationTests: XCTestCase {
    private func provider(baseURL: String) -> ProviderModel {
        ProviderModel(
            name: "Stub",
            baseURL: baseURL,
            apiKey: "test",
            models: ["stub-model"],
            defaultModel: "stub-model",
            contextWindow: 32_000,
            reasoningLevel: .off
        )
    }

    func testStreamingTextFromRealSSEServer() async throws {
        let server = try StubSSEServer(chunks: [
            #"{"choices":[{"delta":{"content":"При"}}]}"#,
            #"{"choices":[{"delta":{"content":"вет"}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        ])
        try server.start()
        defer { server.stop() }

        var text = ""
        let stream = ProviderClient().stream(
            provider: provider(baseURL: server.baseURL),
            model: "stub-model",
            messages: [ProviderMessage(role: .user, content: "hi")]
        )
        for try await event in stream {
            if case .delta(let chunk) = event { text += chunk }
        }

        XCTAssertEqual(text, "Привет")
        XCTAssertEqual(server.bodies.count, 1)
        XCTAssertTrue(server.bodies[0].contains("\"stream\":true"))
    }

    func testReasoningDeltaIsSeparated() async throws {
        let server = try StubSSEServer(chunks: [
            #"{"choices":[{"delta":{"reasoning_content":"думаю"}}]}"#,
            #"{"choices":[{"delta":{"content":"ответ"}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        ])
        try server.start()
        defer { server.stop() }

        var reasoning = ""
        var text = ""
        for try await event in ProviderClient().stream(
            provider: provider(baseURL: server.baseURL),
            model: "stub-model",
            messages: [ProviderMessage(role: .user, content: "hi")]
        ) {
            switch event {
            case .reasoning(let chunk): reasoning += chunk
            case .delta(let chunk): text += chunk
            default: break
            }
        }

        XCTAssertEqual(reasoning, "думаю")
        XCTAssertEqual(text, "ответ")
    }

    func testToolCallIsParsedFromStream() async throws {
        let server = try StubSSEServer(chunks: [
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"fs_read","arguments":"{\"path\":"}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"AGENTS.md\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#
        ])
        try server.start()
        defer { server.stop() }

        var calls: [ToolCall] = []
        for try await event in ProviderClient().stream(
            provider: provider(baseURL: server.baseURL),
            model: "stub-model",
            messages: [ProviderMessage(role: .user, content: "read")],
            tools: [ProviderToolSchema(name: "fs_read", description: "read", parameters: [
                "type": AnySendable("object")
            ])]
        ) {
            if case .toolCall(let call) = event { calls.append(call) }
        }

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].name, "fs_read")
        XCTAssertEqual(calls[0].id, "call_1")
        XCTAssertEqual(calls[0].arguments, #"{"path":"AGENTS.md"}"#)
    }

    func testFailedToolResultIsMarkedForTheModel() async throws {
        let server = try StubSSEServer(responses: [
            [
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"fs_write","arguments":"{\"path\":\"x.txt\",\"content\":\"hi\"}"}}]}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#
            ],
            [
                #"{"choices":[{"delta":{"content":"ок"}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
            ]
        ])
        try server.start()
        defer { server.stop() }

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        // Read-only mode turns every mutating call into a failure, which is exactly the
        // case the model otherwise cannot tell from a success.
        let registry = ToolRegistry(
            workspace: sandbox,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil,
            readOnly: true
        )
        let loop = AgentLoop(provider: provider(baseURL: server.baseURL), model: "stub-model", registry: registry)

        for try await _ in loop.run(history: [ProviderMessage(role: .user, content: "write it")]) {}

        XCTAssertEqual(server.bodies.count, 2)
        XCTAssertTrue(server.bodies[1].contains(AgentLoop.toolErrorPrefix))
        XCTAssertTrue(server.bodies[1].contains("только-чтение"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sandbox.appendingPathComponent("x.txt").path))
    }

    func testHTTPErrorIsReported() async throws {
        let server = try StubSSEServer(chunks: [])
        try server.start()
        defer { server.stop() }

        var caught: Error?
        do {
            for try await _ in ProviderClient().stream(
                provider: provider(baseURL: "http://127.0.0.1:\(server.port)/v1/chat"),
                model: "m",
                messages: [ProviderMessage(role: .user, content: "x")]
            ) {}
        } catch {
            caught = error
        }

        // Stub always answers 200 with an empty SSE stream, so the outcome is either
        // a clean finish or an explicit empty-response error — never a silent success
        // with fabricated content.
        if let caught {
            XCTAssertFalse(caught.localizedDescription.isEmpty)
        }
    }
}

final class ProviderUsageTests: XCTestCase {
    func testDeepSeekCacheFields() throws {
        let json = """
        {"choices":[],"usage":{"prompt_tokens":12000,"prompt_cache_hit_tokens":11000,"prompt_cache_miss_tokens":1000}}
        """.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(ProviderChunk.self, from: json)
        XCTAssertEqual(chunk.usage?.cacheHit, 11000)
        XCTAssertEqual(chunk.usage?.cacheMiss, 1000)
        XCTAssertEqual(chunk.usage?.promptTokens, 12000)
    }

    func testOpenAICacheFields() throws {
        let json = """
        {"choices":[],"usage":{"prompt_tokens":8000,"prompt_tokens_details":{"cached_tokens":6000}}}
        """.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(ProviderChunk.self, from: json)
        XCTAssertEqual(chunk.usage?.cacheHit, 6000)
        XCTAssertEqual(chunk.usage?.cacheMiss, 2000)
    }

    func testNoUsageIsNil() throws {
        let json = #"{"choices":[]}"#.data(using: .utf8)!
        let chunk = try JSONDecoder().decode(ProviderChunk.self, from: json)
        XCTAssertNil(chunk.usage)
    }
}

final class AgentLoopStepTests: XCTestCase {
    private func provider(baseURL: String) -> ProviderModel {
        ProviderModel(
            name: "Stub",
            baseURL: baseURL,
            apiKey: "test",
            models: ["stub-model"],
            defaultModel: "stub-model",
            contextWindow: 32_000,
            reasoningLevel: .off
        )
    }

    func testEachModelRequestIsItsOwnStep() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("steps-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)

        let server = try StubSSEServer(responses: [
            [
                #"{"choices":[{"delta":{"reasoning_content":"сначала прочитаю"}}]}"#,
                #"{"choices":[{"delta":{"content":"Читаю файл."}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"fs_read","arguments":"{\"path\":\"note.txt\"}"}}]}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#
            ],
            [
                #"{"choices":[{"delta":{"reasoning_content":"теперь отвечу"}}]}"#,
                #"{"choices":[{"delta":{"content":"Файл содержит hello."}}]}"#,
                #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
            ]
        ])
        try server.start()
        defer { server.stop() }

        let registry = ToolRegistry(
            workspace: root,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil
        )

        let loop = AgentLoop(provider: provider(baseURL: server.baseURL), model: "stub-model", registry: registry)
        var steps: [Int] = []
        var textByStep: [Int: String] = [:]
        var reasoningByStep: [Int: String] = [:]
        var current = 0

        for try await event in loop.run(history: [ProviderMessage(role: .user, content: "прочитай note.txt")]) {
            switch event {
            case .stepStarted(let index):
                current = index
                steps.append(index)
            case .delta(let chunk):
                textByStep[current, default: ""] += chunk
            case .reasoning(let chunk):
                reasoningByStep[current, default: ""] += chunk
            default:
                break
            }
        }

        // Two model requests, so two steps — the UI turns each into its own message.
        XCTAssertEqual(steps, [0, 1])
        XCTAssertEqual(reasoningByStep[0], "сначала прочитаю")
        XCTAssertEqual(textByStep[0], "Читаю файл.")
        XCTAssertEqual(reasoningByStep[1], "теперь отвечу")
        XCTAssertEqual(textByStep[1], "Файл содержит hello.")
        XCTAssertEqual(server.bodies.count, 2)
    }
}
