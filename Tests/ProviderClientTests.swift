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