import Foundation

struct ProviderMessage: Sendable {
    enum Role: String, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    var role: Role
    var content: String
    var toolCalls: [ToolCall] = []
    var toolCallID: String?
    var images: [Data] = []

    init(role: Role, content: String, toolCalls: [ToolCall] = [], toolCallID: String? = nil, images: [Data] = []) {
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID
        self.images = images
    }
}

struct ToolCall: Identifiable, Sendable, Equatable {
    let id: String
    var name: String
    var arguments: String
}

enum ProviderEvent: Sendable {
    case delta(String)
    case reasoning(String)
    case toolCall(ToolCall)
    /// Token accounting from the final chunk. `cacheHit` is the part of the prompt the
    /// provider served from its prefix cache; zero means the cache was missed.
    case usage(promptTokens: Int, cacheHit: Int, cacheMiss: Int)
    case finished(reason: String)
}

enum ProviderError: LocalizedError, Sendable {
    case badURL(String)
    case http(status: Int, body: String)
    case emptyResponse

    /// The provider refused the request because the prompt does not fit its window.
    /// Detected by status and wording: every vendor phrases it differently, but the
    /// status is always a client error and the body always names the context length.
    var isContextOverflow: Bool {
        guard case .http(let status, let body) = self else { return false }
        guard [400, 413, 422].contains(status) else { return false }
        let text = body.lowercased()
        let markers = [
            "context length", "context_length", "context window", "maximum context",
            "prompt is too long", "too many tokens", "input is too long", "exceeds the maximum",
            "request too large", "reduce the length", "maximum number of tokens",
            "tokens exceed", "context overflow"
        ]
        return markers.contains { text.contains($0) }
    }

    var errorDescription: String? {
        switch self {
        case .badURL(let value):
            "Некорректный Base URL: \(value)"
        case .http(let status, let body):
            body.isEmpty ? "Провайдер вернул HTTP \(status)." : "HTTP \(status): \(body)"
        case .emptyResponse:
            "Провайдер вернул пустой ответ."
        }
    }
}

struct ProviderToolSchema: Sendable {
    let name: String
    let description: String
    let parameters: [String: AnySendable]

    init(name: String, description: String, parameters: [String: AnySendable]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// Small helper so dynamic JSON schema dictionaries can cross concurrency boundaries.
struct AnySendable: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

struct ProviderClient: Sendable {
    /// One session for every request: keeps the connection to the provider alive
    /// between turns, so only the first request pays DNS and TLS.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 6
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    func stream(
        provider: ProviderModel,
        model: String,
        messages: [ProviderMessage],
        tools: [ProviderToolSchema] = []
    ) -> AsyncThrowingStream<ProviderEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard let url = Self.chatURL(baseURL: provider.baseURL) else {
                        throw ProviderError.badURL(provider.baseURL)
                    }

                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 300
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if !provider.apiKey.isEmpty {
                        request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = try Self.encodeRequest(
                        model: model,
                        messages: messages,
                        reasoning: provider.reasoningLevel,
                        tools: tools
                    )

                    let (bytes, response) = try await Self.session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var body = Data()
                        for try await byte in bytes {
                            body.append(byte)
                            if body.count > 2_000 { break }
                        }
                        let text = String(data: body, encoding: .utf8) ?? ""
                        throw ProviderError.http(status: http.statusCode, body: String(text.prefix(400)))
                    }

                    var sawAnything = false
                    var pending: [Int: (id: String, name: String, arguments: String)] = [:]
                    var finishReason: String?
                    var usage: ProviderChunk.Usage?

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload.isEmpty { continue }
                        if payload == "[DONE]" { break }

                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(ProviderChunk.self, from: data),
                              let choice = chunk.choices?.first else {
                            continue
                        }

                        if let reason = choice.finishReason, !reason.isEmpty {
                            finishReason = reason
                        }
                        if let reported = chunk.usage {
                            usage = reported
                        }

                        if let delta = choice.delta {
                            if let reasoning = delta.reasoningContent ?? delta.reasoning, !reasoning.isEmpty {
                                sawAnything = true
                                continuation.yield(.reasoning(reasoning))
                            }
                            if let content = delta.content, !content.isEmpty {
                                sawAnything = true
                                continuation.yield(.delta(content))
                            }
                            if let calls = delta.toolCalls {
                                for call in calls {
                                    var entry = pending[call.index] ?? (id: "", name: "", arguments: "")
                                    if let id = call.id, !id.isEmpty { entry.id = id }
                                    if let name = call.function?.name, !name.isEmpty { entry.name = name }
                                    if let args = call.function?.arguments { entry.arguments += args }
                                    pending[call.index] = entry
                                    sawAnything = true
                                }
                            }
                        }
                    }

                    for (_, entry) in pending.sorted(by: { $0.key < $1.key }) where !entry.name.isEmpty {
                        continuation.yield(.toolCall(ToolCall(
                            id: entry.id.isEmpty ? UUID().uuidString : entry.id,
                            name: entry.name,
                            arguments: entry.arguments
                        )))
                    }

                    if let usage {
                        continuation.yield(.usage(
                            promptTokens: usage.promptTokens ?? 0,
                            cacheHit: usage.cacheHit,
                            cacheMiss: usage.cacheMiss
                        ))
                    }

                    if sawAnything {
                        continuation.yield(.finished(reason: finishReason ?? "stop"))
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    static func chatURL(baseURL: String) -> URL? {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasSuffix("/chat/completions") {
            return URL(string: trimmed)
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return URL(string: trimmed + "/chat/completions")
    }

    static func encodeRequest(
        model: String,
        messages: [ProviderMessage],
        reasoning: ReasoningLevel,
        tools: [ProviderToolSchema] = []
    ) throws -> Data {
        var payload: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": messages.map(encodeMessage)
        ]
        if reasoning != .off {
            payload["reasoning_effort"] = reasoning.apiValue
        }
        if !tools.isEmpty {
            payload["tools"] = tools.map { tool in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": Self.unwrap(tool.parameters)
                    ]
                ] as [String: Any]
            }
            payload["tool_choice"] = "auto"
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }

    private static func unwrap(_ value: Any) -> Any {
        if let dict = value as? [String: AnySendable] {
            return dict.mapValues { unwrap($0) }
        }
        if let array = value as? [AnySendable] {
            return array.map { unwrap($0.value) }
        }
        if let box = value as? AnySendable {
            return unwrap(box.value)
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues { unwrap($0) }
        }
        if let array = value as? [Any] {
            return array.map { unwrap($0) }
        }
        return value
    }

    private static func encodeMessage(_ message: ProviderMessage) -> [String: Any] {
        var object: [String: Any] = ["role": message.role.rawValue]

        if message.images.isEmpty {
            object["content"] = message.content
        } else {
            var parts: [[String: Any]] = [
                ["type": "text", "text": message.content]
            ]
            for image in message.images {
                let type = image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
                parts.append([
                    "type": "image_url",
                    "image_url": ["url": "data:\(type);base64,\(image.base64EncodedString())"]
                ])
            }
            object["content"] = parts
        }

        if !message.toolCalls.isEmpty {
            object["tool_calls"] = message.toolCalls.map { call in
                [
                    "id": call.id,
                    "type": "function",
                    "function": [
                        "name": call.name,
                        "arguments": call.arguments
                    ]
                ] as [String: Any]
            }
        }
        if let toolCallID = message.toolCallID {
            object["tool_call_id"] = toolCallID
        }
        return object
    }
}

struct ProviderChunk: Decodable, Sendable {
    struct Choice: Decodable, Sendable {
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    struct Delta: Decodable, Sendable {
        let content: String?
        let reasoningContent: String?
        let reasoning: String?
        let toolCalls: [ToolCallDelta]?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
            case reasoning
            case toolCalls = "tool_calls"
        }
    }

    struct ToolCallDelta: Decodable, Sendable {
        struct Function: Decodable, Sendable {
            let name: String?
            let arguments: String?
        }

        let index: Int
        let id: String?
        let function: Function?
    }

    struct Usage: Decodable, Sendable {
        let promptTokens: Int?
        let promptCacheHitTokens: Int?
        let promptCacheMissTokens: Int?
        let promptTokensDetails: Details?

        struct Details: Decodable, Sendable {
            let cachedTokens: Int?

            enum CodingKeys: String, CodingKey {
                case cachedTokens = "cached_tokens"
            }
        }

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
            case promptCacheMissTokens = "prompt_cache_miss_tokens"
            case promptTokensDetails = "prompt_tokens_details"
        }

        /// Providers report the hit either directly (DeepSeek) or under details (OpenAI).
        var cacheHit: Int { promptCacheHitTokens ?? promptTokensDetails?.cachedTokens ?? 0 }

        var cacheMiss: Int {
            if let promptCacheMissTokens { return promptCacheMissTokens }
            guard let promptTokens else { return 0 }
            return max(promptTokens - cacheHit, 0)
        }
    }

    let choices: [Choice]?
    let usage: Usage?
}