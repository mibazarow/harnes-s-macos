import XCTest
@testable import Harness

final class VectorSearchTests: XCTestCase {
    private func vector(_ values: [Float]) -> EmbeddingsService.Vector {
        EmbeddingsService.Vector(values: values, model: "test")
    }

    private func version(_ database: AppDatabase) throws -> Int {
        try database.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT value FROM app_state WHERE key = 'embeddings.version'") ?? -1
        }
    }

    func testTopKMatchesByCosine() async throws {
        let service = EmbeddingsService(database: try AppDatabase(inMemory: true))
        try await service.store(refKind: "memory", refID: "a", vector: vector([1, 0, 0]))
        try await service.store(refKind: "memory", refID: "b", vector: vector([0, 1, 0]))
        try await service.store(refKind: "memory", refID: "c", vector: vector([0.6, 0.8, 0]))

        let hits = try await service.bestMatches(refKind: "memory", query: [1, 0, 0], limit: 2)

        XCTAssertEqual(hits.map(\.refID), ["a", "c"])
        XCTAssertEqual(hits[0].score, 1.0, accuracy: 1e-5)
        XCTAssertEqual(hits[1].score, 0.6, accuracy: 1e-5)
    }

    func testIndexNoticesInsertsAndDeletes() async throws {
        let database = try AppDatabase(inMemory: true)
        let service = EmbeddingsService(database: database)
        try await service.store(refKind: "memory", refID: "a", vector: vector([0.9, 0.44, 0]))

        // First search materializes the resident table.
        _ = try await service.bestMatches(refKind: "memory", query: [1, 0, 0], limit: 2)
        let afterFirst = try version(database)

        try await service.store(refKind: "memory", refID: "closer", vector: vector([1, 0.05, 0]))
        let afterInsert = try version(database)
        XCTAssertGreaterThan(afterInsert, afterFirst, "триггер должен двигать версию")

        let withNew = try await service.bestMatches(refKind: "memory", query: [1, 0, 0], limit: 2)
        XCTAssertEqual(withNew.first?.refID, "closer", "новый вектор должен попасть в индекс")

        try await database.queue.write { db in
            try db.execute(sql: "DELETE FROM embeddings WHERE ref_kind = 'memory' AND ref_id = 'closer'")
        }
        let afterDelete = try await service.bestMatches(refKind: "memory", query: [1, 0, 0], limit: 2)
        XCTAssertFalse(afterDelete.contains { $0.refID == "closer" }, "удалённый вектор должен исчезнуть")
    }

    func testRowsWithAnotherDimensionAreIgnored() async throws {
        let service = EmbeddingsService(database: try AppDatabase(inMemory: true))
        try await service.store(refKind: "memory", refID: "three", vector: vector([1, 0, 0]))
        try await service.store(refKind: "memory", refID: "two", vector: vector([1, 0]))

        let hits = try await service.bestMatches(refKind: "memory", query: [1, 0, 0], limit: 5)

        XCTAssertEqual(hits.map(\.refID), ["three"])
    }

    func testLargeCollectionsFallBackToStreaming() async throws {
        // Cap of 2 with 3 rows forces the streamed path; the answer must be identical.
        let service = EmbeddingsService(database: try AppDatabase(inMemory: true), maxCachedVectors: 2)
        try await service.store(refKind: "memory", refID: "a", vector: vector([1, 0, 0]))
        try await service.store(refKind: "memory", refID: "b", vector: vector([0.5, 0.5, 0]))
        try await service.store(refKind: "memory", refID: "c", vector: vector([0, 1, 0]))

        let hits = try await service.bestMatches(refKind: "memory", query: [1, 0, 0], limit: 2)

        XCTAssertEqual(hits.map(\.refID), ["a", "b"])
    }
}
