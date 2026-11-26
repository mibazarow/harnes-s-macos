import Foundation

/// One selectable model, remembered as "provider id + model name".
///
/// The provider list stopped being the place where the working model is chosen: a
/// provider is a connection, and the two working models are app-wide. This type is the
/// bridge — the settings store keeps the raw string, the pickers show the label, and
/// the resolver turns it back into a provider row plus a model name.
struct ModelChoice: Identifiable, Hashable, Sendable {
    let providerID: String
    let providerName: String
    let model: String

    var id: String { ModelSelection.raw(providerID: providerID, model: model) }
    var label: String { "\(providerName) · \(model)" }
}

enum ModelSelection {
    /// Unit separator: provider ids are UUIDs and model names never contain it.
    static let separator = "\u{1F}"
    static let mainModelKey = "selectedMainModel"

    static func raw(providerID: String, model: String) -> String {
        providerID + separator + model
    }

    /// Every saved model of every provider, in provider order.
    static func choices(_ providers: [ProviderModel]) -> [ModelChoice] {
        var seen: Set<String> = []
        var result: [ModelChoice] = []
        for provider in providers {
            var models = provider.models
            if let fallback = provider.defaultModel, !fallback.isEmpty,
               !models.contains(fallback) {
                models.insert(fallback, at: 0)
            }
            for model in models where !model.isEmpty {
                let choice = ModelChoice(
                    providerID: provider.id, providerName: provider.name, model: model
                )
                guard seen.insert(choice.id).inserted else { continue }
                result.append(choice)
            }
        }
        return result
    }

    /// The remembered choice, but only if that provider still exists and still lists the
    /// model. A stale reference falls through instead of sending a request to a model
    /// the person removed.
    static func resolve(
        _ raw: String,
        in providers: [ProviderModel]
    ) -> (provider: ProviderModel, model: String)? {
        let parts = raw.components(separatedBy: separator)
        guard parts.count == 2, !parts[1].isEmpty else { return nil }
        guard let provider = providers.first(where: { $0.id == parts[0] }) else { return nil }
        let model = parts[1]
        let known = provider.models.contains(model) || provider.defaultModel == model
        guard known else { return nil }
        return (provider, model)
    }

    /// No explicit choice: the first provider and its default model, which is what the
    /// app did before the selectors existed.
    static func fallback(_ providers: [ProviderModel]) -> (provider: ProviderModel, model: String)? {
        guard let provider = providers.first(where: \.isDefault) ?? providers.first else {
            return nil
        }
        let model = provider.defaultModel ?? provider.models.first ?? ""
        guard !model.isEmpty else { return nil }
        return (provider, model)
    }

    static func resolveOrDefault(
        _ raw: String,
        in providers: [ProviderModel]
    ) -> (provider: ProviderModel, model: String)? {
        resolve(raw, in: providers) ?? fallback(providers)
    }
}
