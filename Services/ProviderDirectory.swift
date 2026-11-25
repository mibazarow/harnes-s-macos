import Foundation
import Observation

@MainActor
@Observable
final class ProviderDirectory {
    private let service: ProvidersService?
    private let defaults: UserDefaults

    private(set) var name: String?
    private(set) var model: String?
    private(set) var contextWindow: Int?
    private(set) var lastError: String?

    init(service: ProvidersService?, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    var label: String {
        guard let name else {
            return lastError == nil ? "провайдер не подключён" : "провайдеры: ошибка"
        }
        guard let model, !model.isEmpty else { return name }
        return "\(name) · \(model)"
    }

    func reload() async {
        guard let service else { return }
        do {
            let providers = try await service.list()
            // The working model is an app-wide choice now; the provider row only holds
            // the connection. An empty or stale choice falls back to the first provider.
            let active = ModelSelection.resolveOrDefault(
                defaults.string(forKey: ModelSelection.mainModelKey) ?? "",
                in: providers
            )
            name = active?.provider.name
            model = active?.model
            contextWindow = active?.provider.contextWindow
            lastError = nil
        } catch {
            name = nil
            model = nil
            contextWindow = nil
            lastError = error.localizedDescription
        }
    }
}