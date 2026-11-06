import Accelerate
import Foundation
import GRDB

/// Embeddings for memory items, stored as L2-normalized float32 BLOBs.
/// One backend only: the bundled EmbeddingGemma 2 ONNX model. There is no
/// provider-side `/embeddings` fallback and nothing to configure per provider.
actor EmbeddingsService {
    private let database: AppDatabase
    private let local: LocalEmbedder
    /// Only used to tell "still downloading" from "not installed at all" in errors.
    private let installer: EmbeddingModelInstaller?

    /// Last few query vectors. Repeating a search — or re-running the same command —
    /// costs nothing instead of a full model pass.
    private var queryCache: [(text: String, vector: Vector)] = []
    private let queryCacheLimit = 8

    init(
        database: AppDatabase,
        installer: EmbeddingModelInstaller? = nil,
        local: LocalEmbedder = LocalEmbedder()
    ) {
        self.database = database
        self.installer = installer
        self.local = local
    }

    /// True when a 768-dim local ONNX model is installed on disk.
    nonisolated var hasLocalModel: Bool {
        LocalEmbedder().isAvailableOnDisk
    }

    struct Vector: Sendable {
        let values: [Float]
        let model: String
    }

    func embed(_ texts: [String]) async throws -> [Vector] {
        guard !texts.isEmpty else { return [] }
        guard local.isAvailableOnDisk else {
            let downloading = await installer?.phase.isDownloading ?? false
            throw EmbeddingError.unavailable(
                downloading
                    ? "модель эмбеддингов ещё скачивается, поиск пока текстовый"
                    : "модель эмбеддингов не установлена"
            )
        }
        try await local.prepare()
        return try await local.embed(texts).map { Vector(values: $0, model: "embeddinggemma-2") }
    }

    /// Vector for a search query, cached for repeated searches.
    func queryVector(_ text: String) async -> Vector? {
        if let hit = queryCache.first(where: { $0.text == text }) {
            return hit.vector
        }
        guard let vector = try? await embed([text]).first else { return nil }
        queryCache.append((text, vector))
        if queryCache.count > queryCacheLimit {
            queryCache.removeFirst(queryCache.count - queryCacheLimit)
        }
        return vector
    }

    private func normalize(_ values: [Float]) -> [Float] {
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return values }
        return values.map { $0 / norm }
    }

    /// Stores a vector. `textHash` lets an identical chunk reuse an existing vector
    /// instead of running the model again.
    func store(refKind: String, refID: String, vector: Vector, textHash: String? = nil) throws {
        let blob = Self.encode(vector.values)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO embeddings (ref_kind, ref_id, model, dim, vector, text_hash, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(ref_kind, ref_id, model) DO UPDATE SET
                    dim = excluded.dim,
                    vector = excluded.vector,
                    text_hash = excluded.text_hash,
                    updated_at = excluded.updated_at
                """, arguments: [
                refKind, refID, vector.model, vector.values.count, blob, textHash, Timestamps.now()
            ])
        }
    }

    /// An already computed vector for the same text, if one exists.
    func vector(refKind: String, textHash: String) throws -> Vector? {
        try database.queue.read { db in
            try Row.fetchOne(db, sql: """
                SELECT model, vector FROM embeddings
                WHERE ref_kind = ? AND text_hash = ?
                LIMIT 1
                """, arguments: [refKind, textHash])
            .flatMap { row in
                let blob: Data = row["vector"]
                guard let values = Self.decode(blob) else { return nil }
                return Vector(values: values, model: row["model"])
            }
        }
    }

    /// Top matches by cosine similarity. Dot products run through vDSP and rows are
    /// streamed, so nothing is materialized as a dictionary of vectors.
    func bestMatches(refKind: String, query: [Float], limit: Int) throws -> [(refID: String, score: Double)] {
        guard !query.isEmpty else { return [] }

        return try database.queue.read { db in
            var best: [(refID: String, score: Double)] = []
            best.reserveCapacity(limit + 1)

            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT ref_id, vector FROM embeddings WHERE ref_kind = ?",
                arguments: [refKind]
            )
            while let row = try rows.next() {
                let blob: Data = row["vector"]
                guard let values = Self.decode(blob), values.count == query.count else { continue }
                let score = Double(Self.dot(query, values))
                if best.count < limit {
                    best.append((row["ref_id"], score))
                    if best.count == limit { best.sort { $0.score > $1.score } }
                } else if let worst = best.last, score > worst.score {
                    best[best.count - 1] = (row["ref_id"], score)
                    best.sort { $0.score > $1.score }
                }
            }
            return best.sorted { $0.score > $1.score }
        }
    }

    static func encode(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float]? {
        guard data.count % 4 == 0 else { return nil }
        var values = [Float](repeating: 0, count: data.count / 4)
        _ = values.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        return values
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        return Double(dot(a, b))
    }

    private static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }
}

enum EmbeddingError: LocalizedError {
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason): reason
        }
    }
}
