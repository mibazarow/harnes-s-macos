import Foundation
import GRDB

actor ProvidersService {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func list() throws -> [ProviderModel] {
        try database.queue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM providers
                ORDER BY is_default DESC, name COLLATE NOCASE
                """)
            .map(Self.provider(from:))
        }
    }

    func save(_ provider: ProviderModel) throws -> ProviderModel {
        var provider = provider
        provider.name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.baseURL = provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        provider.updatedAt = Timestamps.now()

        guard !provider.name.isEmpty else {
            throw ConfigurationError.invalidArguments("Название провайдера не может быть пустым.")
        }
        guard URL(string: provider.baseURL)?.scheme != nil else {
            throw ConfigurationError.invalidArguments("Base URL должен быть полным адресом, например https://api.example.com/v1")
        }

        let modelsJSON = try Self.encodeModels(provider.models)

        try database.queue.write { db in
            let exists = try Row.fetchOne(
                db,
                sql: "SELECT 1 FROM providers WHERE id = ?",
                arguments: [provider.id]
            ) != nil

            if !exists {
                let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM providers") ?? 0
                if count == 0 {
                    provider.isDefault = true
                }
            }

            if provider.isDefault {
                try db.execute(sql: "UPDATE providers SET is_default = 0")
            }

            if exists {
                try db.execute(sql: """
                    UPDATE providers SET
                        name = ?, base_url = ?, api_key = ?, models_json = ?,
                        default_model = ?, context_window = ?, reasoning_level = ?,
                        temperature = ?, is_default = ?, health = ?, last_check_at = ?, updated_at = ?
                    WHERE id = ?
                    """, arguments: [
                    provider.name, provider.baseURL, provider.apiKey, modelsJSON,
                    provider.defaultModel, provider.contextWindow, provider.reasoningLevel.rawValue,
                    provider.temperature,
                    provider.isDefault ? 1 : 0,
                    provider.health, provider.lastCheckAt, provider.updatedAt, provider.id
                ])
            } else {
                try db.execute(sql: """
                    INSERT INTO providers (
                        id, name, base_url, api_key, models_json, default_model,
                        context_window, reasoning_level, temperature, is_default, health,
                        last_check_at, created_at, updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                    provider.id, provider.name, provider.baseURL, provider.apiKey, modelsJSON,
                    provider.defaultModel, provider.contextWindow, provider.reasoningLevel.rawValue,
                    provider.temperature,
                    provider.isDefault ? 1 : 0,
                    provider.health, provider.lastCheckAt, provider.createdAt, provider.updatedAt
                ])
            }
        }

        return provider
    }

    func delete(id: String) throws {
        try database.queue.write { db in
            let wasDefault = try Bool.fetchOne(
                db,
                sql: "SELECT is_default FROM providers WHERE id = ?",
                arguments: [id]
            ) ?? false

            try db.execute(sql: "DELETE FROM providers WHERE id = ?", arguments: [id])

            if wasDefault {
                if let next = try String.fetchOne(
                    db,
                    sql: "SELECT id FROM providers ORDER BY created_at LIMIT 1"
                ) {
                    try db.execute(
                        sql: "UPDATE providers SET is_default = 1 WHERE id = ?",
                        arguments: [next]
                    )
                }
            }
        }
    }

    func setDefault(id: String) throws {
        try database.queue.write { db in
            try db.execute(sql: "UPDATE providers SET is_default = 0")
            try db.execute(
                sql: "UPDATE providers SET is_default = 1, updated_at = ? WHERE id = ?",
                arguments: [Timestamps.now(), id]
            )
        }
    }

    func fetchModels(baseURL: String, apiKey: String) async throws -> [String] {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else {
            throw ConfigurationError.invalidArguments("Некорректный Base URL.")
        }
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        components.path += "models"
        guard let url = components.url else {
            throw ConfigurationError.invalidArguments("Некорректный Base URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ConfigurationError.downloadFailed(error.localizedDescription)
        }

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ConfigurationError.downloadFailed(
                "HTTP \(http.statusCode): \(String(body.prefix(200)))"
            )
        }

        let ids: [String]
        if let payload = try? JSONDecoder().decode(ModelEnvelope.self, from: data) {
            ids = (payload.data ?? payload.models ?? []).map(\.id)
        } else if let list = try? JSONDecoder().decode([ModelEntry].self, from: data) {
            ids = list.map(\.id)
        } else {
            throw ConfigurationError.downloadFailed("Ответ не похож на список моделей.")
        }

        let models = Array(Set(ids)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !models.isEmpty else {
            throw ConfigurationError.downloadFailed("Провайдер вернул пустой список моделей.")
        }
        return models
    }

    private static func provider(from row: Row) -> ProviderModel {
        let modelsJSON: String? = row["models_json"]
        let models: [String]
        if let modelsJSON, let data = modelsJSON.data(using: .utf8) {
            models = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        } else {
            models = []
        }

        return ProviderModel(
            id: row["id"],
            name: row["name"],
            baseURL: row["base_url"],
            apiKey: row["api_key"] ?? "",
            models: models,
            defaultModel: row["default_model"],
            contextWindow: row["context_window"],
            reasoningLevel: ReasoningLevel(rawValue: row["reasoning_level"] ?? "off") ?? .off,
            temperature: row["temperature"] ?? ProviderModel.defaultTemperature,
            isDefault: (row["is_default"] as Int) == 1,
            health: row["health"],
            lastCheckAt: row["last_check_at"],
            createdAt: row["created_at"],
            updatedAt: row["updated_at"]
        )
    }

    private static func encodeModels(_ models: [String]) throws -> String {
        let data = try JSONEncoder().encode(models)
        return String(data: data, encoding: .utf8) ?? "[]"
    }
}

private struct ModelEnvelope: Decodable {
    let data: [ModelEntry]?
    let models: [ModelEntry]?
}

private struct ModelEntry: Decodable {
    let id: String
}