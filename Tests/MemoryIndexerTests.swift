import XCTest
@testable import Harness

/// R33.4: a saved fact is embedded immediately, and a broken embedder never blocks it.
final class MemoryIndexerTests: XCTestCase {
    private actor StubSink: MemoryEmbeddingSink {
        var stored: [(id: Int64, hash: String)] = []
        var cached: [String: EmbeddingsService.Vector] = [:]
        var embeddable: Bool

        init(embeddable: Bool = true) { self.embeddable = embeddable }

        func cachedVector(hash: String) async -> EmbeddingsService.Vector? { cached[hash] }

        func embedOne(_ text: String) async -> EmbeddingsService.Vector? {
            guard embeddable else { return nil }
            return EmbeddingsService.Vector(values: [1, 0, 0], model: "stub")
        }

        func store(id: Int64, vector: EmbeddingsService.Vector, hash: String) async {
            stored.append((id, hash))
        }

        var written: [(id: Int64, hash: String)] { stored }

        func setCached(_ hash: String) {
            cached[hash] = EmbeddingsService.Vector(values: [0, 1, 0], model: "stub")
        }
    }

    func testSaveWritesAVectorImmediately() async {
        let sink = StubSink()
        let ok = await MemoryIndexer.index(id: 7, content: "Сервер на Ubuntu", sink: sink)
        XCTAssertTrue(ok)
        let written = await sink.written
        XCTAssertEqual(written.count, 1)
        XCTAssertEqual(written.first?.id, 7)
        XCTAssertEqual(written.first?.hash, MemoryService.hash("Сервер на Ubuntu"))
    }

    func testCachedVectorIsReusedWithoutEmbedding() async {
        let sink = StubSink(embeddable: false)
        let hash = MemoryService.hash("Уже считалось")
        await sink.setCached(hash)

        let ok = await MemoryIndexer.index(id: 1, content: "Уже считалось", sink: sink)
        XCTAssertTrue(ok, "готовый вектор должен переиспользоваться")
    }

    func testMissingModelIsNotAnError() async {
        let sink = StubSink(embeddable: false)
        let ok = await MemoryIndexer.index(id: 2, content: "Факт", sink: sink)
        XCTAssertFalse(ok)
        let written = await sink.written
        XCTAssertTrue(written.isEmpty)
    }

    func testNoSinkIsSilentlySkipped() async {
        let ok = await MemoryIndexer.index(id: 3, content: "Факт", sink: nil)
        XCTAssertFalse(ok)
    }
}
