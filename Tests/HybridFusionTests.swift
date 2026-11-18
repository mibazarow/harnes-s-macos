import XCTest
@testable import Harness

/// P31: lexical keeps the majority of the weight, semantic is an addition, and a
/// missing model degrades to lexical-only with a reason instead of failing.
final class HybridFusionTests: XCTestCase {
    func testNoSemanticReturnsLexicalExactly() {
        let lexical: [Int64: Double] = [1: 0.8, 2: 0.4]
        XCTAssertEqual(HybridFusion.fuse(lexical: lexical, semantic: [:]), lexical)
        XCTAssertTrue(HybridFusion.fuse(lexical: [:], semantic: [:]).isEmpty)
    }

    func testLexicalWeightIsLargerThanSemantic() {
        XCTAssertGreaterThan(HybridFusion.lexicalWeight, HybridFusion.semanticWeight)
        let fused = HybridFusion.fuse(lexical: [1: 1], semantic: [1: 1])
        XCTAssertEqual(fused[1] ?? 0, 1.0, accuracy: 0.0001)
    }

    func testOneVectorDoesNotDropLexicalCandidates() {
        let fused = HybridFusion.fuse(lexical: [1: 0.9, 2: 0.5], semantic: [3: 0.95])
        XCTAssertEqual(Set(fused.keys), [1, 2, 3])
        XCTAssertGreaterThan(fused[1] ?? 0, fused[3] ?? 0, "лексика весит больше семантики")
    }

    func testModeExplainsWhySemanticIsOff() {
        let noVector = HybridSearch.mode(hasQueryVector: false, semanticCount: 0)
        XCTAssertEqual(noVector.0, .lexicalOnly)
        XCTAssertEqual(noVector.1, "no_query_vector")

        let noMatches = HybridSearch.mode(hasQueryVector: true, semanticCount: 0)
        XCTAssertEqual(noMatches.0, .lexicalOnly)
        XCTAssertEqual(noMatches.1, "no_vectors")

        let hybrid = HybridSearch.mode(hasQueryVector: true, semanticCount: 2)
        XCTAssertEqual(hybrid.0, .hybrid)
        XCTAssertNil(hybrid.1)
    }

    func testSearchWithoutModelStillAnswersLexically() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        _ = try await memory.add("Сервер работает на Ubuntu")

        let emptyModel = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let embeddings = EmbeddingsService(
            database: database, local: LocalEmbedder(modelDirectory: emptyModel)
        )
        let box = LogBox()
        let outcome = await HybridSearch(
            memory: memory,
            embeddings: embeddings,
            log: { box.append($0) }
        ).searchDetailed("сервер")

        XCTAssertEqual(outcome.mode, .lexicalOnly)
        XCTAssertEqual(outcome.reason, "no_query_vector")
        XCTAssertFalse(outcome.hits.isEmpty)
        XCTAssertTrue(box.value.contains { $0.contains("lexical_only") })
    }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    var value: [String] {
        lock.lock()
        defer { lock.unlock() }
        return lines
    }
}
