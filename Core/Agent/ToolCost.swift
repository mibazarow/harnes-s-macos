import Foundation

/// Cost of tool traffic as the provider actually receives it.
///
/// Counting only the cleaned text missed the JSON envelope of every call and result —
/// ids, roles, braces, and escaping of newlines and quotes — which is why a measured
/// prompt came in 23% above the estimate on tool-heavy sessions. Everything here is
/// measured on serialized JSON.
enum ToolCost {
    /// Per-item protocol overhead: `"role"`, `"tool_call_id"`, braces, commas.
    private static let envelope = 10

    static func call(name: String, arguments: String) -> Int {
        serialized(["name": name, "arguments": arguments]) + envelope
    }

    static func result(_ output: String) -> Int {
        serialized(["content": output]) + envelope
    }

    /// One completed call: the assistant entry plus the matching `tool` message.
    static func exchange(name: String, arguments: String, output: String) -> Int {
        call(name: name, arguments: arguments) + result(output)
    }

    static func catalog(_ schemas: [ProviderToolSchema]) -> Int {
        schemas.reduce(0) { total, schema in
            total + serialized([
                "name": schema.name,
                "description": schema.description,
                "parameters": schema.parameters.mapValues(\.value)
            ])
        }
    }

    static func catalog(_ definitions: [ToolDefinition]) -> Int {
        definitions.reduce(0) { total, definition in
            total + serialized([
                "name": definition.name,
                "description": definition.description,
                "parameters": definition.parameters.mapValues(\.value)
            ])
        }
    }

    private static func serialized(_ payload: [String: Any]) -> Int {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            // Fallback: measure the values only. Worse, but never zero.
            return payload.values.reduce(0) { $0 + TokenEstimator.tokens(in: String(describing: $1)) }
        }
        return TokenEstimator.tokens(in: json)
    }
}

extension TokenEstimator {
    /// Cost of a string as it appears inside a JSON document (quoted, escaped).
    static func jsonTokens(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        guard let data = try? JSONEncoder().encode(text),
              let json = String(data: data, encoding: .utf8) else {
            return tokens(in: text)
        }
        return tokens(in: json)
    }
}
