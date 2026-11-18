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

    /// Resident copy of one collection: ids and a row-major float32 matrix. Materialized
    /// only while the whole collection fits in memory, so a search never sees a partial
    /// index. This is the seam an ANN index would replace later; callers only ever see
    /// `bestMatches`.
    private struct VectorTable {
        var ids: [String]
        var matrix: [Float]
        var dim: Int
    }

    private var tables: [String: VectorTable] = [:]
    private var tableVersions: [String: String] = [:]

    /// 40k × 768 × 4 B ≈ 118 MB. Above this, holding the matrix costs more than it
    /// saves: the streamed path stays correct, and a larger collection is the point to
    /// add an ANN index. `shortcut: brute-force scan, upgrade to ANN above ~200k rows`.
    private let maxCachedVectors: Int

    init(
        database: AppDatabase,
        installer: EmbeddingModelInstaller? = nil,
        local: LocalEmbedder = LocalEmbedder(),
        maxCachedVectors: Int = 40_000
    ) {
        self.database = database
        self.installer = installer
        self.local = local
        self.maxCachedVectors = maxCachedVectors
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

    /// One statement for both the single and the batch path; they differed only in the
    /// timestamp source and drifted apart otherwise.
    private static func upsert(
        _ db: Database,
        refKind: String,
        refID: String,
        vector: Vector,
        textHash: String?,
        updatedAt: String
    ) throws {
        try db.execute(sql: """
            INSERT INTO embeddings (ref_kind, ref_id, model, dim, vector, text_hash, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(ref_kind, ref_id, model) DO UPDATE SET
                dim = excluded.dim,
                vector = excluded.vector,
                text_hash = excluded.text_hash,
                updated_at = excluded.updated_at
            """, arguments: [
            refKind, refID, vector.model, vector.values.count,
            Self.encode(vector.values), textHash, updatedAt
        ])
    }

    /// Stores a vector. `textHash` lets an identical chunk reuse an existing vector
    /// instead of running the model again.
    func store(refKind: String, refID: String, vector: Vector, textHash: String? = nil) throws {
        try database.queue.write { db in
            try Self.upsert(
                db, refKind: refKind, refID: refID, vector: vector,
                textHash: textHash, updatedAt: Timestamps.now()
            )
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

    /// Vectors already computed for these text hashes, keyed by hash. One query per
    /// batch instead of one per chunk: the indexer asks about every chunk of a file.
    func vectors(refKind: String, textHashes: [String]) throws -> [String: Vector] {
        guard !textHashes.isEmpty else { return [:] }
        var result: [String: Vector] = [:]
        result.reserveCapacity(textHashes.count)

        // SQLite limits the number of bound variables per statement.
        let batchSize = 400
        var start = 0
        while start < textHashes.count {
            let slice = Array(textHashes[start..<min(start + batchSize, textHashes.count)])
            start += batchSize
            let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
            try database.queue.read { db in
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT text_hash, model, vector FROM embeddings
                        WHERE ref_kind = ? AND text_hash IN (\(placeholders))
                        """,
                    arguments: StatementArguments([refKind] + slice)
                )
                for row in rows {
                    guard let hash: String = row["text_hash"] else { continue }
                    guard result[hash] == nil else { continue }
                    let blob: Data = row["vector"]
                    guard let values = Self.decode(blob) else { continue }
                    result[hash] = Vector(values: values, model: row["model"])
                }
            }
        }
        return result
    }

    /// Stores many vectors in one transaction. Same semantics as `store`, batched.
    func storeBatch(
        refKind: String,
        items: [(refID: String, vector: Vector, textHash: String)]
    ) throws {
        guard !items.isEmpty else { return }
        let now = Timestamps.now()
        try database.queue.write { db in
            for item in items {
                try Self.upsert(
                    db, refKind: refKind, refID: item.refID, vector: item.vector,
                    textHash: item.textHash, updatedAt: now
                )
            }
        }
    }

    /// Top matches by cosine similarity.
    ///
    /// Vectors are L2-normalized, so a dot product is the cosine. When the collection
    /// fits in memory the search runs as one SGEMM-style matrix-vector product through
    /// Accelerate instead of one decode and one call per row; otherwise it streams rows
    /// and does the same math per row. Results and ordering are identical either way.
    func bestMatches(refKind: String, query: [Float], limit: Int) throws -> [(refID: String, score: Double)] {
        guard !query.isEmpty, limit > 0 else { return [] }
        if let cached = try cachedMatches(refKind: refKind, query: query, limit: limit) {
            return cached
        }
        return try streamedMatches(refKind: refKind, query: query, limit: limit)
    }

    // MARK: - Resident index

    private func cachedMatches(
        refKind: String,
        query: [Float],
        limit: Int
    ) throws -> [(refID: String, score: Double)]? {
        let version = try indexVersion()
        let key = "\(refKind)#\(query.count)"
        if let table = tables[key], tableVersions[key] == version {
            return Self.topMatches(table, query: query, limit: limit)
        }

        // Load only a complete collection: a partial table would silently lose matches.
        let count = try database.queue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM embeddings WHERE ref_kind = ? AND dim = ?",
                arguments: [refKind, query.count]
            ) ?? 0
        }
        guard count > 0, count <= maxCachedVectors else {
            tables[key] = nil
            tableVersions[key] = nil
            return nil
        }

        var ids: [String] = []
        var matrix: [Float] = []
        ids.reserveCapacity(count)
        matrix.reserveCapacity(count * query.count)
        try database.queue.read { db in
            let rows = try Row.fetchCursor(
                db,
                sql: "SELECT ref_id, vector FROM embeddings WHERE ref_kind = ? AND dim = ?",
                arguments: [refKind, query.count]
            )
            while let row = try rows.next() {
                let blob: Data = row["vector"]
                guard let values = Self.decode(blob), values.count == query.count else { continue }
                ids.append(row["ref_id"])
                matrix.append(contentsOf: values)
            }
        }
        guard !ids.isEmpty else { return [] }

        // One resident table per collection: a query with another dimension replaces it
        // rather than keeping both matrices in memory.
        tables = tables.filter { !$0.key.hasPrefix(refKind + "#") }
        let table = VectorTable(ids: ids, matrix: matrix, dim: query.count)
        tables[key] = table
        tableVersions[key] = version
        return Self.topMatches(table, query: query, limit: limit)
    }

    private func indexVersion() throws -> String {
        try database.queue.read { db in
            try String.fetchOne(
                db, sql: "SELECT value FROM app_state WHERE key = 'embeddings.version'"
            ) ?? "0"
        }
    }

    private static func topMatches(
        _ table: VectorTable,
        query: [Float],
        limit: Int
    ) -> [(refID: String, score: Double)] {
        let rows = table.ids.count
        guard rows > 0, table.dim == query.count else { return [] }

        var scores = [Float](repeating: 0, count: rows)
        table.matrix.withUnsafeBufferPointer { matrix in
            query.withUnsafeBufferPointer { queryBuffer in
                scores.withUnsafeMutableBufferPointer { out in
                    cblas_sgemv(
                        CblasRowMajor, CblasNoTrans,
                        Int32(rows), Int32(table.dim),
                        1, matrix.baseAddress, Int32(table.dim),
                        queryBuffer.baseAddress, 1,
                        0, out.baseAddress, 1
                    )
                }
            }
        }

        var best: [(refID: String, score: Double)] = []
        best.reserveCapacity(limit)
        for index in 0..<rows {
            let score = Double(scores[index])
            if best.count < limit {
                best.append((table.ids[index], score))
                if best.count == limit { best.sort { $0.score > $1.score } }
            } else if let worst = best.last, score > worst.score {
                best[best.count - 1] = (table.ids[index], score)
                best.sort { $0.score > $1.score }
            }
        }
        return best
    }

    // MARK: - Streamed fallback

    private func streamedMatches(
        refKind: String,
        query: [Float],
        limit: Int
    ) throws -> [(refID: String, score: Double)] {
        try database.queue.read { db in
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
