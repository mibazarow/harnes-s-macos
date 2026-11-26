import XCTest
@testable import Harness

/// The working model is chosen once, app-wide, from what the providers saved.
final class ModelSelectionTests: XCTestCase {
    private func provider(
        _ name: String, id: String = UUID().uuidString,
        models: [String], defaultModel: String? = nil, isDefault: Bool = false
    ) -> ProviderModel {
        ProviderModel(
            id: id, name: name, baseURL: "https://example.com/v1",
            models: models, defaultModel: defaultModel, isDefault: isDefault
        )
    }

    func testChoicesCoverEverySavedModelOfEveryProvider() {
        let first = provider("OpenAI", models: ["gpt-4o", "gpt-4.1"])
        let second = provider("Local", models: ["llama3"])
        let choices = ModelSelection.choices([first, second])
        XCTAssertEqual(choices.map(\.label), [
            "OpenAI · gpt-4o", "OpenAI · gpt-4.1", "Local · llama3"
        ])
    }

    func testChoicesIncludeDefaultModelMissingFromList() {
        let p = provider("P", models: ["a"], defaultModel: "b")
        let choices = ModelSelection.choices([p])
        XCTAssertEqual(choices.map(\.model), ["b", "a"])
    }

    func testChoicesDoNotDuplicateModels() {
        let p = provider("P", models: ["a", "a", "b"], defaultModel: "a")
        XCTAssertEqual(ModelSelection.choices([p]).map(\.model), ["a", "b"])
    }

    func testResolveReturnsProviderAndModel() {
        let p = provider("P", id: "prov-1", models: ["m"])
        let raw = ModelSelection.raw(providerID: "prov-1", model: "m")
        let resolved = ModelSelection.resolve(raw, in: [p])
        XCTAssertEqual(resolved?.provider.id, "prov-1")
        XCTAssertEqual(resolved?.model, "m")
    }

    func testStaleProviderOrModelIsRejected() {
        let p = provider("P", id: "prov-1", models: ["m"])
        XCTAssertNil(ModelSelection.resolve(
            ModelSelection.raw(providerID: "gone", model: "m"), in: [p]
        ))
        XCTAssertNil(ModelSelection.resolve(
            ModelSelection.raw(providerID: "prov-1", model: "removed"), in: [p]
        ))
        XCTAssertNil(ModelSelection.resolve("", in: [p]))
        XCTAssertNil(ModelSelection.resolve("no-separator", in: [p]))
    }

    func testFallbackUsesDefaultProvider() {
        let first = provider("First", models: ["a"])
        let second = provider("Second", models: ["b"], defaultModel: "b", isDefault: true)
        let fallback = ModelSelection.fallback([first, second])
        XCTAssertEqual(fallback?.provider.name, "Second")
        XCTAssertEqual(fallback?.model, "b")
    }

    func testResolveOrDefaultFallsBackWhenStoredChoiceIsStale() {
        let p = provider("P", id: "prov-1", models: ["m"], defaultModel: "m", isDefault: true)
        let resolved = ModelSelection.resolveOrDefault("gone\u{1F}m", in: [p])
        XCTAssertEqual(resolved?.provider.id, "prov-1")
        XCTAssertEqual(resolved?.model, "m")
    }

    @MainActor
    func testSettingsPersistTheChoice() {
        let name = "models-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.mainModel, "")

        settings.mainModel = ModelSelection.raw(providerID: "p", model: "main")

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.mainModel, ModelSelection.raw(providerID: "p", model: "main"))
    }
}

/// The store reads the same choice the settings tab writes.
@MainActor
final class ModelSelectionStoreTests: XCTestCase {
    private func makeStore() async throws -> (ChatStore, AppServices, ProviderModel) {
        let database = try AppDatabase(inMemory: true)
        let services = AppServices(database: database)
        let main = try await services.providers.save(ProviderModel(
            name: "Main", baseURL: "https://main.example/v1",
            models: ["main-a", "main-b"], defaultModel: "main-a", isDefault: true
        ))
        let chat = ChatStore(services: services)
        let name = "store-models-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        chat.modelDefaults = defaults
        return (chat, services, main)
    }

    func testMainModelComesFromTheChoiceNotTheProviderDefault() async throws {
        let (chat, services, main) = try await makeStore()
        chat.modelDefaults.set(
            ModelSelection.raw(providerID: main.id, model: "main-b"),
            forKey: ModelSelection.mainModelKey
        )
        let resolved = try await chat.resolvedMain(services)
        XCTAssertEqual(resolved?.provider.id, main.id)
        XCTAssertEqual(resolved?.model, "main-b")
    }

    func testEmptyChoiceFallsBackToFirstProvider() async throws {
        let (chat, services, main) = try await makeStore()
        let resolved = try await chat.resolvedMain(services)
        XCTAssertEqual(resolved?.provider.id, main.id)
        XCTAssertEqual(resolved?.model, "main-a")
    }
}
