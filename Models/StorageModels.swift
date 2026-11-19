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
    static let defaultTemperature: Double = 0.2
    static let temperatureRange: ClosedRange<Double> = 0...2

    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    var models: [String]
    var defaultModel: String?
    /// Optional cheaper model for background work (read-only subagents, style card).
    /// Nil means "use `defaultModel`".
    var cheapModel: String?
    var contextWindow: Int
    var reasoningLevel: ReasoningLevel
    /// Sampling temperature for this provider. Individual per provider: a chatty
    /// model and a terse one rarely want the same value.
    var temperature: Double
    /// Price per 1 000 000 tokens, in whatever currency the provider bills in.
    /// Optional: without it the app simply does not estimate cost.
    var inputPrice: Double?
    var outputPrice: Double?
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
        cheapModel: String? = nil,
        contextWindow: Int = 128_000,
        reasoningLevel: ReasoningLevel = .off,
        temperature: Double = ProviderModel.defaultTemperature,
        inputPrice: Double? = nil,
        outputPrice: Double? = nil,
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
        self.cheapModel = cheapModel
        self.contextWindow = contextWindow
        self.reasoningLevel = reasoningLevel
        self.temperature = temperature
        self.inputPrice = inputPrice
        self.outputPrice = outputPrice
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
    let pinned: Bool
    let hits: Int
    let lastUsedAt: String?
    /// R30.2: the axis the prompt groups by. `kind` stays for compatibility.
    var area: String = "fact"
    /// The verbatim fragment of the user's message that authorized this record.
    var quote: String?
    /// R33.2: the record this one replaces. The old row stays, but out of the prompt.
    var supersedesID: Int64?
    /// R33.3: 0 means "worthless, collect when untouched"; 1 is the default for every
    /// record and keeps it forever. 2–3 are reserved for a future manual ranking.
    var importance: Int = 1
    /// Last write of any kind, as stored. `createdAt` never moves; this does.
    var updatedAt: String = ""
    var score: Double?

    /// R30.8: `area/id`. The old slug was the first three words of the body, so every
    /// edit changed the address and the prompt carried things like
    /// `fact/📌-preferences/пользователя-зовут-миха`. An id never moves with the text.
    var address: String {
        "\(area)/\(id)"
    }

    /// Body shown in the prompt. Short records are verbatim; a long one is cut at a
    /// sentence boundary instead of mid-word.
    var promptBody: String {
        Self.promptBody(content, limit: Tuning.memoryPromptBodyChars)
    }

    /// `address: body`, the unit the prompt renders and the token budget measures.
    var promptText: String {
        "\(address): \(promptBody)"
    }

    static func promptBody(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let boundaries: Set<Character> = [".", "!", "?", "…", "\n"]
        if let cut = head.lastIndex(where: { boundaries.contains($0) }),
           head.distance(from: head.startIndex, to: cut) >= limit / 3 {
            return String(head[...cut]) + "…"
        }
        return head + "…"
    }

    var snippet: String {
        let singleLine = content.replacingOccurrences(of: "\n", with: " ")
        return singleLine.count > 110 ? String(singleLine.prefix(109)) + "…" : singleLine
    }
}