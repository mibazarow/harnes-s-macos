import XCTest
@testable import Harness

/// R34.2: the window follows the model; a typed number is an override, not the default.
final class ModelContextPreferencesTests: XCTestCase {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ctx-\(UUID().uuidString)")!
    }

    /// R45: the number in the provider settings is the truth. The old contract let a
    /// substring guess ("deepseek" → 128 000) override it, and that is the bug.
    func testProviderNumberWinsOverTheKnownModelTable() {
        let resolution = ModelContextPreferences.resolve(
            providerID: "p", model: "deepseek-v4.1-flash-1017", providerWindow: 245_000,
            defaults: defaults()
        )
        XCTAssertEqual(resolution.window, 245_000)
        XCTAssertEqual(resolution.source, .provider)
    }

    /// A row still holding the default is "never set": the table fills it in.
    func testDefaultProviderWindowLetsTheModelTableFillIn() {
        let resolution = ModelContextPreferences.resolve(
            providerID: "p", model: "gemini-2.5-pro",
            providerWindow: ProviderModel.defaultContextWindow,
            defaults: defaults()
        )
        XCTAssertEqual(resolution.window, 1_000_000)
        XCTAssertEqual(resolution.source, .model)
    }

    /// Clearing the field writes zero; that must read as "from the model" too.
    func testClearedProviderWindowFallsBackToTheModel() {
        let resolution = ModelContextPreferences.resolve(
            providerID: "p", model: "claude-sonnet-4", providerWindow: 0,
            defaults: defaults()
        )
        XCTAssertEqual(resolution.window, 200_000)
        XCTAssertEqual(resolution.source, .model)
    }

    /// Unknown model and an untouched row: the row's default is all there is.
    func testUnknownModelWithDefaultRowKeepsTheDefault() {
        let resolution = ModelContextPreferences.resolve(
            providerID: "p", model: "my-local-model",
            providerWindow: ProviderModel.defaultContextWindow,
            defaults: defaults()
        )
        XCTAssertEqual(resolution.window, ProviderModel.defaultContextWindow)
        XCTAssertEqual(resolution.source, .provider)
    }

    func testSwitchingModelChangesTheBudgetWithoutCode() {
        let d = defaults()
        let small = ModelContextPreferences.resolve(
            providerID: "p", model: "gemma-3-9b", providerWindow: 128_000, defaults: d
        )
        let large = ModelContextPreferences.resolve(
            providerID: "p", model: "gemini-2.5-pro", providerWindow: 128_000, defaults: d
        )
        XCTAssertLessThan(small.window, large.window)
        XCTAssertEqual(small.source, .model)
        XCTAssertEqual(large.source, .model)
    }

    func testManualOverrideBeatsTheModelTable() {
        let d = defaults()
        ModelContextPreferences.setManual(true, providerID: "p", defaults: d)
        let resolution = ModelContextPreferences.resolve(
            providerID: "p", model: "claude-sonnet-4", providerWindow: 64_000, defaults: d
        )
        XCTAssertEqual(resolution.window, 64_000)
        XCTAssertEqual(resolution.source, .manual)
    }

    func testUnknownModelFallsBackToTheProviderRow() {
        let resolution = ModelContextPreferences.resolve(
            providerID: "p", model: "my-local-model", providerWindow: 16_384,
            defaults: defaults()
        )
        XCTAssertEqual(resolution.window, 16_384)
        XCTAssertEqual(resolution.source, .provider)
    }

    func testUsableLeavesRoomForTheAnswer() {
        XCTAssertEqual(ModelContextPreferences.usable(window: 128_000, outputReserve: 16_000), 112_000)
        XCTAssertEqual(ModelContextPreferences.usable(window: 1_000, outputReserve: 16_000), 1_000)
    }

    func testBudgetFollowsTheResolvedWindow() {
        let composer = ContextComposer()
        let small = composer.budget(for: 32_000, thresholdPercent: 80)
        let large = composer.budget(for: 200_000, thresholdPercent: 80)
        XCTAssertLessThan(small.usable, large.usable)
        XCTAssertLessThan(small.thresholdTokens, large.thresholdTokens)
    }

    func testSourceLabelsAreDistinct() {
        XCTAssertEqual(ContextWindowSource.model.label, "модель")
        XCTAssertEqual(ContextWindowSource.provider.label, "из настроек")
        XCTAssertEqual(ContextWindowSource.manual.label, "вручную")
    }
}
