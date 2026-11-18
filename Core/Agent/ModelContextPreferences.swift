import Foundation

/// R34.2: the working window comes from the model, not from a number typed by hand.
///
/// A provider row has one `context_window` field, and it was the only source. Switching
/// from a 32k model to a 128k one left the budget at 32k (half the window wasted) or the
/// other way round (a 400 from the provider). Here the window is resolved from the model
/// name when it is known, and the stored value is used only as a fallback or as an
/// explicit override.
enum ContextWindowSource: String, Sendable {
    /// Taken from the model name.
    case model
    /// The provider row's value, used because the model is unknown.
    case provider
    /// The person typed a number; nothing overrides it.
    case manual

    var label: String {
        switch self {
        case .model: "модель"
        case .provider: "провайдер"
        case .manual: "вручную"
        }
    }
}

struct ContextWindowResolution: Equatable, Sendable {
    let window: Int
    let source: ContextWindowSource
}

enum ModelContextPreferences {
    /// Known families. Deliberately conservative: a wrong high value is worse than a
    /// wrong low one, because a too-large window never triggers compaction and the
    /// provider answers 400 instead.
    static let known: [(needle: String, window: Int)] = [
        ("gemini-1.5-pro", 2_000_000),
        ("gemini", 1_000_000),
        ("claude", 200_000),
        ("gpt-4.1", 1_000_000),
        ("gpt-4o", 128_000),
        ("gpt-5", 400_000),
        ("o1", 200_000),
        ("o3", 200_000),
        ("o4", 200_000),
        ("deepseek", 128_000),
        ("qwen", 128_000),
        ("llama-3", 128_000),
        ("llama", 128_000),
        ("mistral", 32_000),
        ("mixtral", 32_000),
        ("gemma", 8_192),
        ("grok", 131_072),
        ("command-r", 128_000),
        ("yi", 200_000)
    ]

    static func knownWindow(for model: String) -> Int? {
        let lower = model.lowercased()
        return known.first { lower.contains($0.needle) }?.window
    }

    /// Manual overrides live in UserDefaults: a per-provider flag is enough, and it
    /// avoids a migration for a setting the person can flip back.
    private static let manualPrefix = "contextWindow.manual."

    static func isManual(providerID: String, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: manualPrefix + providerID)
    }

    static func setManual(_ manual: Bool, providerID: String, defaults: UserDefaults = .standard) {
        defaults.set(manual, forKey: manualPrefix + providerID)
    }

    static func resolve(
        providerID: String,
        model: String,
        providerWindow: Int,
        defaults: UserDefaults = .standard
    ) -> ContextWindowResolution {
        if isManual(providerID: providerID, defaults: defaults) {
            return ContextWindowResolution(window: max(providerWindow, 1_000), source: .manual)
        }
        if let known = knownWindow(for: model) {
            return ContextWindowResolution(window: known, source: .model)
        }
        return ContextWindowResolution(window: max(providerWindow, 1_000), source: .provider)
    }

    /// `usable` is the window minus the room reserved for the answer. Every budget
    /// downstream is derived from it, so a model switch changes them all at once.
    static func usable(window: Int, outputReserve: Int) -> Int {
        max(window - outputReserve, 1_000)
    }
}
