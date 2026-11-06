import Foundation
import GRDB

/// Embeddings for memory items, stored as L2-normalized float32 BLOBs.
/// Uses any OpenAI-compatible `/embeddings` endpoint of the active provider.
actor EmbeddingsService {
    private let database: AppDatabase
    private let providers: ProvidersService
    private let local: LocalEmbedder

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
        let model = provider.embedModel ?? provider.defaultModel ?? provider.models.first ?? ""
        guard !model.isEmpty else { return nil }
        return (provider, model)
    }

    func embed(_ texts: [String]) async throws -> [Vector] {
        // Local model first: no network, no cost, deterministic.
        if local.isAvailableOnDisk {
            do {
                try await local.prepare()
                var vectors: [Vector] = []
                for text in texts {
                    let values = try await local.embed(text)
                    vectors.append(Vector(values: values, model: "embeddinggemma-2"))
                }
                return vectors
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

    private func normalize(_ values: [Float]) -> [Float] {
        let norm = sqrt(values.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return values }
        return values.map { $0 / norm }
    }

    func store(refKind: String, refID: String, vector: Vector) throws {
        let blob = Self.encode(vector.values)
        try database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO embeddings (ref_kind, ref_id, model, dim, vector, text_hash, updated_at)
                VALUES (?, ?, ?, ?, ?, NULL, ?)
                ON CONFLICT(ref_kind, ref_id, model) DO UPDATE SET
                    dim = excluded.dim,
                    vector = excluded.vector,
                    updated_at = excluded.updated_at
                """, arguments: [
                refKind, refID, vector.model, vector.values.count, blob, Timestamps.now()
            ])
        }
    }

    func storedVectors(refKind: String) throws -> [(refID: String, model: String, values: [Float])] {
        try database.queue.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT ref_id, model, vector FROM embeddings WHERE ref_kind = ?",
                arguments: [refKind]
            ).compactMap { row in
                let blob: Data = row["vector"]
                guard let values = Self.decode(blob) else { return nil }
                return (row["ref_id"] as String, row["model"] as String, values)
            }
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
        var dot: Float = 0
        for index in a.indices { dot += a[index] * b[index] }
        return Double(dot)
    }
}

private struct EmbeddingResponse: Decodable {
    struct Item: Decodable {
        let index: Int
        let embedding: [Float]
    }

    let data: [Item]
}