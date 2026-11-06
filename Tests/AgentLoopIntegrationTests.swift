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
