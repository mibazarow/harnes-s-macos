import Foundation
import Tokenizers

/// Thin wrapper so the embedder can hold a tokenizer without exposing the
/// swift-transformers generic type all over the codebase.
enum TokenizerLoader {
    struct Handle: Sendable {
        let tokenizer: any Tokenizer
        let chatTemplate: String?

        func encode(_ text: String, maxLength: Int) -> [Int] {
            var ids = tokenizer.encode(text: text, addSpecialTokens: true)
            if ids.count > maxLength {
                ids = Array(ids.prefix(maxLength - 1)) + [1]
            }
            return ids
        }
    }

    static func load(folder: URL) async throws -> Handle {
        let tokenizer = try await AutoTokenizer.from(modelFolder: folder)
        return Handle(tokenizer: tokenizer, chatTemplate: nil)
    }
}