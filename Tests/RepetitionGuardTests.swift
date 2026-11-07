import XCTest
@testable import Harness

final class RepetitionGuardTests: XCTestCase {
    private func repeated(_ unit: String, _ times: Int) -> String {
        String(repeating: unit, count: times)
    }

    // MARK: - Loops that must be caught

    func testRepeatedSentenceIsALoop() {
        let text = "Сначала я проверю файл. " + repeated("Нужно проверить конфигурацию сборки. ", 8)
        XCTAssertTrue(RepetitionGuard.isLooping(text))
    }

    func testRepeatedShortPhraseIsALoop() {
        let text = "Вот результат:\n" + repeated("и снова проверяю и снова проверяю. ", 10)
        XCTAssertTrue(RepetitionGuard.isLooping(text))
    }

    func testRepeatedLineIsALoop() {
        let line = "- проверить, что сборка проходит без ошибок и предупреждений"
        let text = "План:\n" + Array(repeating: line, count: 8).joined(separator: "\n")
        XCTAssertTrue(RepetitionGuard.isLooping(text))
    }

    func testRepeatedWordIsALoop() {
        let intro = String(repeating: "Сначала опишу, что уже сделано и что осталось. ", count: 12)
        let text = intro + "Проверяю " + Array(repeating: "снова", count: 20).joined(separator: " ")
        XCTAssertTrue(RepetitionGuard.isLooping(text))
    }

    // MARK: - Healthy text that must not be touched

    func testNormalAnswerIsNotALoop() {
        let text = """
        Нашёл причину. В `ContextComposer.swift:74` хвост считается от полного окна модели, \
        а не от бюджета после системного промпта. На окне 128 000 это давало хвост 40 000 \
        вместо 12 000, и тест ловил расхождение. Поправил одну строку и прогнал весь набор: \
        161 тест, два пропущенных, падений нет.
        """
        XCTAssertFalse(RepetitionGuard.isLooping(text))
    }

    func testShortAnswerIsNeverALoop() {
        XCTAssertFalse(RepetitionGuard.isLooping("Готово."))
        XCTAssertFalse(RepetitionGuard.isLooping(""))
    }

    func testMarkdownDividerIsNotALoop() {
        let text = "Раздел первый\n\n" + repeated("-----", 30) + "\n\nРаздел второй"
        XCTAssertFalse(RepetitionGuard.isLooping(text))
    }

    func testRepeatedWhitespaceIsNotALoop() {
        let text = "Текст ответа.\n" + repeated("\n", 200) + "Продолжение."
        XCTAssertFalse(RepetitionGuard.isLooping(text))
    }

    func testListWithSimilarButDifferentItemsIsNotALoop() {
        let text = """
        - прочитать конфигурацию сборки
        - прочитать конфигурацию тестов
        - прочитать конфигурацию линтера
        - прочитать конфигурацию форматтера
        - прочитать конфигурацию деплоя
        - прочитать конфигурацию документации
        - прочитать конфигурацию примеров
        """
        XCTAssertFalse(RepetitionGuard.isLooping(text))
    }

    // MARK: - Trimming

    func testTrimKeepsTheSensibleHead() {
        let head = "Начинаю проверку. Файл на месте, права в порядке."
        let text = head + " " + repeated("Дальше проверяю ещё раз то же самое. ", 24)
        let trimmed = RepetitionGuard.trimmed(text)
        XCTAssertTrue(trimmed.hasPrefix("Начинаю проверку"))
        XCTAssertLessThan(trimmed.count, text.count)
        XCTAssertFalse(RepetitionGuard.isLooping(trimmed))
    }

    func testTrimLeavesHealthyTextUntouched() {
        let text = "Короткий нормальный ответ без повторов."
        XCTAssertEqual(RepetitionGuard.trimmed(text), text)
    }
}
