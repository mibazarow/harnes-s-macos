import Foundation
import Observation

@MainActor
@Observable
final class ProviderDirectory {
    private let service: ProvidersService?

    private(set) var name: String?
    private(set) var model: String?
    private(set) var contextWindow: Int?
    private(set) var lastError: String?

    init(service: ProvidersService?) {
        self.service = service
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
            let active = providers.first(where: \.isDefault) ?? providers.first
            name = active?.name
            model = active?.defaultModel
            contextWindow = active?.contextWindow
            lastError = nil
        } catch {
            name = nil
            model = nil
            contextWindow = nil
            lastError = error.localizedDescription
        }
    }
}