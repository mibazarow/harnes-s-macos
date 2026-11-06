import XCTest
@testable import Harness

final class LocalEmbedderTests: XCTestCase {
    func testModelFilesPresent() {
        XCTAssertTrue(
            LocalEmbedder().isAvailableOnDisk,
            "модель EmbeddingGemma должна лежать в ~/HARNES_S_DATA/models/embeddinggemma-2"
        )
    }

    func testEmbeddingIsNormalizedAndDeterministic() async throws {
        let embedder = LocalEmbedder()
        guard embedder.isAvailableOnDisk else {
            throw XCTSkip("модель не установлена")
        }

        let first = try await embedder.embed("пароль от почты лежит в сейфе")
        XCTAssertEqual(first.count, 768)

        let norm = sqrt(first.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.01)

        let second = try await embedder.embed("пароль от почты лежит в сейфе")
        let similarity = EmbeddingsService.cosine(first, second)
        XCTAssertGreaterThan(similarity, 0.999)
    }

    func testSemanticSimilarityBeatsUnrelatedText() async throws {
        let embedder = LocalEmbedder()
        guard embedder.isAvailableOnDisk else {
            throw XCTSkip("модель не установлена")
        }

        let password = try await embedder.embed("пароль от почтового ящика")
        let related = try await embedder.embed("доступ к email аккаунту")
        let unrelated = try await embedder.embed("сегодня солнечная погода в Москве")

        let relatedScore = EmbeddingsService.cosine(password, related)
        let unrelatedScore = EmbeddingsService.cosine(password, unrelated)

        XCTAssertGreaterThan(relatedScore, unrelatedScore)
    }
}