import CryptoKit
import Foundation

/// Fingerprint of the byte-stable part of a request: the system prompt and the tool
/// catalog.
///
/// A provider's prefix cache keys on exact bytes. Appending a message at the end keeps
/// the cached prefix valid; rewriting any earlier block — memory order, a date line, a
/// counter — invalidates everything after it. Logging this hash next to `prompt_tokens`
/// and `cache_hit` is what turns "the cache is cold again" into a number that can be
/// compared between turns.
///
/// Only the system text and the schemas are hashed. History is append-only by design,
/// so its own prefix cannot move; if the hash changes, the cause is in the fixed part.
enum PromptPrefix {
    static func hash(system: String, tools: [ProviderToolSchema]) -> String {
        let payload: [String: Any] = [
            "system": system,
            "tools": tools.map { tool in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": normalize(tool.parameters)
                ] as [String: Any]
            }
        ]

        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            ?? Data(system.utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Same unwrapping `ProviderClient` does before serializing a request, so the hash
    /// is taken over the shape that actually goes on the wire.
    private static func normalize(_ value: Any) -> Any {
        if let dict = value as? [String: AnySendable] {
            return dict.mapValues { normalize($0) }
        }
        if let array = value as? [AnySendable] {
            return array.map { normalize($0.value) }
        }
        if let box = value as? AnySendable {
            return normalize(box.value)
        }
        if let dict = value as? [String: Any] {
            return dict.mapValues { normalize($0) }
        }
        if let array = value as? [Any] {
            return array.map { normalize($0) }
        }
        return value
    }
}
