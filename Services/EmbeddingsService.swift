import Accelerate
import Foundation
import GRDB

/// Embeddings for memory items, stored as L2-normalized float32 BLOBs.
/// Uses the local ONNX model when it is on disk, otherwise an OpenAI-compatible
/// `/embeddings` endpoint of the active provider.
actor EmbeddingsService {
    private let database: AppDatabase
    private let providers: ProvidersService
    private let local: LocalEmbedder

    /// Last few query vectors. Repeating a search — or re-running the same command —
    /// costs nothing instead of a full model pass.
    private var queryCache: [(text: String, vector: Vector)] = []
    private let queryCacheLimit = 8

    init(database: AppDatabase, providers: ProvidersService, local: LocalEmbedder = LocalEmbedder()) {
        self.database = database
        self.providers = providers
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

    func embedModel() async -> (provider: ProviderModel, model: String)? {
        guard let list = try? await providers.list() else { return nil }
        guard let provider = list.first(where: \.isDefault) ?? list.first else { return nil }
        // Only the explicitly configured embedding model. Falling back to the chat
        // model would send a completion model to /embeddings and fail obscurely.
        let model = provider.embedModel ?? ""
        guard !model.isEmpty else { return nil }
        return (provider, model)
    }

    func embed(_ texts: [String]) async throws -> [Vector] {
        guard !texts.isEmpty else { return [] }

        // Local model first: no network, no cost, deterministic.
        if local.isAvailableOnDisk {
            do {
                try await local.prepare()
                return try await local.embed(texts).map { Vector(values: $0, model: "embeddinggemma-2") }
            } catch {
                // fall through to the provider
            }
        }

        guard let (provider, model) = await embedModel() else {
            throw ProviderError.badURL("нет ни локальной модели, ни embedding-модели у провайдера")
        }

        var trimmed = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed + "/embeddings") else {
            throw ProviderError.badURL(provider.baseURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !provider.apiKey.isEmpty {
            request.setValue("Bearer \(provider.apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "input": texts
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError.http(status: http.statusCode, body: String(body.prefix(300)))
        }

        let payload = try JSONDecoder().decode(EmbeddingResponse.self, from: data)
        return payload.data
            .sorted { $0.index < $1.index }
            .map { Vector(values: normalize($0.embedding), model: model) }
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

private struct EmbeddingResponse: Decodable {
    struct Item: Decodable {
        let index: Int
        let embedding: [Float]
    }

    let data: [Item]
}
