import XCTest
@testable import Harness

final class TokenEstimatorTests: XCTestCase {
    private func ratio(_ text: String) -> Double {
        Double(text.count) / Double(TokenEstimator.tokens(in: text))
    }

    func testRussianTextCostsMoreThanThreeCharsPerToken() {
        let text = String(
            repeating: "Проверяю конфигурацию сборки и ищу, почему тесты падают после мержа. ",
            count: 10
        )
        // Measured median on real traffic is ~2.32 characters per token; the old flat
        // divisor of 3 undercounted by ~23%.
        XCTAssertLessThan(ratio(text), 2.8, "русский текст не должен считаться как 3 символа на токен")
        XCTAssertGreaterThan(ratio(text), 1.8)
    }

    func testEnglishCodeCostsAboutThreeToFourCharsPerToken() {
        let code = String(
            repeating: "func loadFile(at path: String) throws -> Data { return try Data(contentsOf: URL(fileURLWithPath: path)) }\n",
            count: 10
        )
        XCTAssertGreaterThan(ratio(code), 3.0)
        XCTAssertLessThan(ratio(code), 4.2)
    }

    func testMixedPromptIsCloserToMeasuredRatioThanFlatDivider() {
        let text = """
        Проверяю сборку. В `ContextComposer.swift:74` хвост считается от полного окна модели,
        а не от бюджета после системного промпта. На окне 128 000 это давало хвост 40 000
        вместо 12 000, и тест ловил расхождение. Поправил одну строку и прогнал весь набор.
        """
        let estimated = TokenEstimator.tokens(in: text)
        let flat = (text.unicodeScalars.count + 2) / 3
        // The weighted estimate must be higher than the old one: the error was always
        // in the direction of undercounting.
        XCTAssertGreaterThan(estimated, flat)
    }

    func testEmptyStringIsZero() {
        XCTAssertEqual(TokenEstimator.tokens(in: ""), 0)
    }

    func testNeverReturnsZeroForNonEmptyText() {
        XCTAssertGreaterThanOrEqual(TokenEstimator.tokens(in: "я"), 1)
    }
}

final class UsageServiceTests: XCTestCase {
    func testCostUsesPerMillionPrices() {
        let cost = UsageService.cost(
            promptTokens: 1_000_000,
            completionTokens: 1_000_000,
            inputPrice: 0.27,
            outputPrice: 1.10
        )
        XCTAssertEqual(cost ?? 0, 1.37, accuracy: 0.0001)
    }

    func testCostIsNilWithoutPrices() {
        XCTAssertNil(UsageService.cost(
            promptTokens: 100,
            completionTokens: 100,
            inputPrice: nil,
            outputPrice: nil
        ))
    }

    func testTotalsAccumulateAndPersist() async throws {
        let database = try AppDatabase()
        let usage = UsageService(database: database)

        await usage.add(promptTokens: 1_000, completionTokens: 200, cachedTokens: 800, cost: 0.01)
        await usage.add(promptTokens: 500, completionTokens: 100, cachedTokens: 400, cost: 0.005)

        let totals = await usage.totals()
        XCTAssertEqual(totals.promptTokens, 1_500)
        XCTAssertEqual(totals.completionTokens, 300)
        XCTAssertEqual(totals.cachedTokens, 1_200)
        XCTAssertEqual(totals.cost, 0.015, accuracy: 0.0001)

        // A second instance reads the same numbers from the database.
        let fresh = UsageService(database: database)
        let reloaded = await fresh.totals()
        XCTAssertEqual(reloaded.promptTokens, 1_500)
        XCTAssertEqual(reloaded.completionTokens, 300)
    }
}