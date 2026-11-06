import Foundation

enum ReasoningLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case off
    case minimal
    case medium
    case maximum

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: "Выключено"
        case .minimal: "Минимальный"
        case .medium: "Средний"
        case .maximum: "Максимальный"
        }
    }

    var apiValue: String {
        switch self {
        case .off: "off"
        case .minimal: "low"
        case .medium: "medium"
        case .maximum: "high"
        }
    }
}

struct ProviderModel: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    var models: [String]
    var defaultModel: String?
    var embedModel: String?
    var contextWindow: Int
    var reasoningLevel: ReasoningLevel
    var isDefault: Bool
    var health: String
    var lastCheckAt: String?
    var createdAt: String
    var updatedAt: String

    init(
        id: String = UUID().uuidString,
        name: String = "",
        baseURL: String = "",
        apiKey: String = "",
        models: [String] = [],
        defaultModel: String? = nil,
        embedModel: String? = nil,
        contextWindow: Int = 128_000,
        reasoningLevel: ReasoningLevel = .off,
        isDefault: Bool = false,
        health: String = "unknown",
        lastCheckAt: String? = nil,
        createdAt: String = Timestamps.now(),
        updatedAt: String = Timestamps.now()
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.models = models
        self.defaultModel = defaultModel
        self.embedModel = embedModel
        self.contextWindow = contextWindow
        self.reasoningLevel = reasoningLevel
        self.isDefault = isDefault
        self.health = health
        self.lastCheckAt = lastCheckAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var host: String {
        URL(string: baseURL)?.host ?? baseURL
    }

    var summary: String {
        guard let defaultModel, !defaultModel.isEmpty else {
            return models.isEmpty ? "модели не загружены" : "\(models.count) моделей"
        }
        return "\(models.count) моделей · \(defaultModel)"
    }
}

struct SecretItem: Identifiable, Sendable, Equatable {
    let id: Int64
    let alias: String
    let value: String
    let note: String?
    let createdAt: String
    let updatedAt: String
}

struct MemoryItem: Identifiable, Sendable, Equatable {
    let id: Int64
    let scope: String
    let content: String
    let kind: String
    let tags: [String]
    let createdAt: String
    var score: Double?

    var snippet: String {
        let singleLine = content.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 110 ? String(singleLine.prefix(109)) + "…" : singleLine
    }
}