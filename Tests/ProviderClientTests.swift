import XCTest
@testable import Harness

final class ProviderClientTests: XCTestCase {
    func testChatURLAppendsCompletions() {
        XCTAssertEqual(
            ProviderClient.chatURL(baseURL: "https://api.example.com/v1")?.absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
        XCTAssertEqual(
            ProviderClient.chatURL(baseURL: "https://api.example.com/v1/")?.absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
        XCTAssertEqual(
            ProviderClient.chatURL(baseURL: "https://api.example.com/v1/chat/completions")?.absoluteString,
            "https://api.example.com/v1/chat/completions"
        )
        XCTAssertNil(ProviderClient.chatURL(baseURL: "   "))
    }

    /// R24.3: the provider cache is prefix-based; ask for it explicitly and pin the slot.
    func testEncodeRequestAsksForThePrefixCache() throws {
        let data = try ProviderClient.encodeRequest(
            model: "m",
            messages: [ProviderMessage(role: .user, content: "hi")],
            reasoning: .off,
            cacheKey: "slot-1",
            cacheFields: true
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["cache_prompt"] as? Bool, true)
        XCTAssertEqual(json["prompt_cache_key"] as? String, "slot-1")
    }

    func testEncodeRequestWithoutAKeyLeavesTheFieldOut() throws {
        let data = try ProviderClient.encodeRequest(
            model: "m",
            messages: [ProviderMessage(role: .user, content: "hi")],
            reasoning: .off,
            cacheFields: true
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["cache_prompt"] as? Bool, true)
        XCTAssertNil(json["prompt_cache_key"])
    }

    func testCacheFieldsGoOnlyToLocalServers() throws {
        XCTAssertTrue(ProviderClient.isLocal(baseURL: "http://127.0.0.1:2019/v1"))
        XCTAssertTrue(ProviderClient.isLocal(baseURL: "http://192.168.1.122:8080/v1"))
        XCTAssertFalse(ProviderClient.isLocal(baseURL: "https://api.openai.com/v1"))

        let cloud = try ProviderClient.encodeRequest(
            model: "m", messages: [ProviderMessage(role: .user, content: "hi")],
            reasoning: .off, cacheKey: "slot-1", cacheFields: false
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: cloud) as? [String: Any])
        XCTAssertNil(json["cache_prompt"])
        XCTAssertNil(json["prompt_cache_key"])
    }

    func testEncodeRequestSetsStreamAndReasoning() throws {
        let data = try ProviderClient.encodeRequest(
            model: "test-model",
            messages: [ProviderMessage(role: .user, content: "привет")],
            reasoning: .medium
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["model"] as? String, "test-model")
        XCTAssertEqual(json["stream"] as? Bool, true)
        XCTAssertEqual(json["temperature"] as? Double, 0.2)
        XCTAssertEqual(json["reasoning_effort"] as? String, "medium")

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        XCTAssertEqual(messages[0]["content"] as? String, "привет")
    }

    func testEncodeRequestUsesProviderTemperature() throws {
        let data = try ProviderClient.encodeRequest(
            model: "m",
            messages: [ProviderMessage(role: .user, content: "x")],
            reasoning: .off,
            temperature: 0.9
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["temperature"] as? Double, 0.9)
    }

    func testEncodeRequestCarriesAntiRepetitionPenalties() throws {
        let sampling = SamplingOptions(temperature: 0.2, maxTokens: 8_192)
        let data = try ProviderClient.encodeRequest(
            model: "m",
            messages: [ProviderMessage(role: .user, content: "x")],
            reasoning: .off,
            sampling: sampling
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["presence_penalty"] as? Double, 0.2)
        XCTAssertEqual(json["frequency_penalty"] as? Double, 0.15)
        XCTAssertEqual(json["max_tokens"] as? Int, 8_192)
    }

    func testMinimalSamplingDropsPenaltiesButKeepsTemperature() throws {
        let full = SamplingOptions(temperature: 0.2, maxTokens: 8_192)
        let minimal = full.minimal
        XCTAssertNil(minimal.presencePenalty)
        XCTAssertNil(minimal.frequencyPenalty)
        XCTAssertEqual(minimal.temperature, 0.2)
        XCTAssertEqual(minimal.maxTokens, 8_192)

        let data = try ProviderClient.encodeRequest(
            model: "m",
            messages: [ProviderMessage(role: .user, content: "x")],
            reasoning: .off,
            sampling: minimal
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["presence_penalty"])
        XCTAssertNil(json["frequency_penalty"])
    }

    func testUnsupportedParameterDetection() {
        XCTAssertTrue(ProviderClient.rejectsSamplingFields(
            "{\"error\":{\"message\":\"Unrecognized request argument supplied: presence_penalty\"}}"
        ))
        XCTAssertTrue(ProviderClient.rejectsSamplingFields(
            "Unsupported parameter: 'max_tokens' is not supported with this model."
        ))
        XCTAssertFalse(ProviderClient.rejectsSamplingFields(
            "{\"error\":{\"message\":\"Incorrect API key provided\"}}"
        ))
    }

    func testEncodeRequestOmitsReasoningWhenOff() throws {
        let data = try ProviderClient.encodeRequest(
            model: "m",
            messages: [ProviderMessage(role: .user, content: "x")],
            reasoning: .off
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(json["reasoning_effort"])
    }

    func testEncodeRequestIncludesToolsAndImages() throws {
        let tool = ProviderToolSchema(
            name: "fs_read",
            description: "read",
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable(["path": ["type": "string"]]),
                "required": AnySendable(["path"])
            ]
        )

        let data = try ProviderClient.encodeRequest(
            model: "m",
            messages: [ProviderMessage(role: .user, content: "что тут", images: [Data([0x89, 0x50, 0x4E, 0x47])])],
            reasoning: .minimal,
            tools: [tool]
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["reasoning_effort"] as? String, "low")
        XCTAssertEqual(json["tool_choice"] as? String, "auto")

        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        let function = try XCTUnwrap(tools[0]["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "fs_read")

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let parts = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1]["type"] as? String, "image_url")
    }

    func testHybridCosineAndBlobRoundTrip() {
        let values: [Float] = [0.6, 0.8]
        let blob = EmbeddingsService.encode(values)
        let decoded = EmbeddingsService.decode(blob)
        XCTAssertEqual(decoded, values)
        XCTAssertEqual(EmbeddingsService.cosine(values, values), 1.0, accuracy: 0.0001)
        XCTAssertEqual(EmbeddingsService.cosine(values, [0.8, -0.6]), 0.0, accuracy: 0.0001)
    }

    func testToolRegistryRejectsUnknownTool() async {
        let registry = ToolRegistry(
            workspace: FileManager.default.temporaryDirectory,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil
        )
        let result = await registry.execute(ToolCall(id: "1", name: "nope", arguments: "{}"))
        XCTAssertTrue(result.isError)
    }

    func testPlainTextStripsHTML() {
        let html = "<html><head><style>b{}</style></head><body><p>Привет</p><div>Мир</div><script>x()</script></body></html>"
        let text = ToolRegistry.plainText(fromHTML: html, limit: 1_000)
        XCTAssertTrue(text.contains("Привет"))
        XCTAssertTrue(text.contains("Мир"))
        XCTAssertFalse(text.contains("<p>"))
        XCTAssertFalse(text.contains("x()"))
    }
}
final class ProviderRetryTests: XCTestCase {
    private func provider(_ baseURL: String) -> ProviderModel {
        ProviderModel(
            name: "Stub",
            baseURL: baseURL,
            apiKey: "test",
            models: ["m"],
            defaultModel: "m",
            contextWindow: 32_000,
            reasoningLevel: .off
        )
    }

    func testRetriesRateLimitsBeforeAnyByte() async throws {
        let server = try StubSSEServer(
            responses: [
                [#"{"error":"slow down"}"#],
                [#"{"error":"slow down"}"#],
                [
                    #"{"choices":[{"delta":{"content":"ок"}}]}"#,
                    #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
                ]
            ],
            statusCodes: [429, 429, 200]
        )
        try server.start()
        defer { server.stop() }

        var text = ""
        let client = ProviderClient(retryDelays: [0.01, 0.01, 0.01])
        for try await event in client.stream(
            provider: provider(server.baseURL),
            model: "m",
            messages: [ProviderMessage(role: .user, content: "hi")]
        ) {
            if case .delta(let chunk) = event { text += chunk }
        }

        XCTAssertEqual(text, "ок")
        XCTAssertEqual(server.bodies.count, 3)
    }

    func testUsageOnlyChunkIsReported() async throws {
        let server = try StubSSEServer(responses: [[
            #"{"choices":[{"delta":{"content":"ok"}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":1234,"completion_tokens":56}}"#
        ]])
        try server.start()
        defer { server.stop() }
        var prompt: Int?
        var completion: Int?
        for try await event in ProviderClient().stream(
            provider: provider(server.baseURL), model: "m",
            messages: [ProviderMessage(role: .user, content: "hi")]
        ) {
            if case .usage(let input, let output, _, _) = event {
                prompt = input
                completion = output
            }
        }
        XCTAssertEqual(prompt, 1234)
        XCTAssertEqual(completion, 56)
    }

    func testDoesNotRetryClientErrors() async throws {
        let server = try StubSSEServer(responses: [[#"{"error":"bad"}"#]], statusCodes: [400])
        try server.start()
        defer { server.stop() }

        let client = ProviderClient(retryDelays: [0.01, 0.01, 0.01])
        do {
            for try await _ in client.stream(
                provider: provider(server.baseURL),
                model: "m",
                messages: [ProviderMessage(role: .user, content: "hi")]
            ) {}
            XCTFail("400 не должен считаться успехом")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("400"), error.localizedDescription)
        }
        XCTAssertEqual(server.bodies.count, 1)
    }

    func testGivesUpAfterTheRetryLadder() async throws {
        let server = try StubSSEServer(responses: [[#"{"error":"down"}"#]], statusCodes: [503])
        try server.start()
        defer { server.stop() }

        let client = ProviderClient(retryDelays: [0.01, 0.01])
        do {
            for try await _ in client.stream(
                provider: provider(server.baseURL),
                model: "m",
                messages: [ProviderMessage(role: .user, content: "hi")]
            ) {}
            XCTFail("503 не должен считаться успехом")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("503"), error.localizedDescription)
        }
        XCTAssertEqual(server.bodies.count, 3)
    }

    func testTransientStatusClassification() {
        XCTAssertTrue(ProviderClient.isTransient(status: 429))
        XCTAssertTrue(ProviderClient.isTransient(status: 502))
        XCTAssertFalse(ProviderClient.isTransient(status: 400))
        XCTAssertFalse(ProviderClient.isTransient(status: 401))
    }
}
