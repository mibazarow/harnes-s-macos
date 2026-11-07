import XCTest
@testable import Harness

final class HonestyGuardTests: XCTestCase {
    private func note(_ user: String, _ answer: String, tools: Int = 0, errored: Bool = false) -> String? {
        FalseSuccessGuard.note(
            userText: user,
            assistantText: answer,
            toolCallsInTurn: tools,
            lastToolErrored: errored
        )
    }

    // MARK: - Real claims

    func testShortConfirmationWithoutToolsIsFlagged() {
        XCTAssertNotNil(note("Создай файл note.txt в рабочей папке", "Готово, создал файл note.txt."))
        XCTAssertNotNil(note("Удали папку build", "Удалил."))
        XCTAssertNotNil(note("Запомни, что я люблю тёмную тему", "Запомнил."))
    }

    func testFailedToolProducesTheErrorVariant() {
        let text = note("Удали файл", "Готово, удалил.", tools: 1, errored: true)
        XCTAssertEqual(text, FalseSuccessGuard.failedToolNote)
    }

    func testPassiveClaimWithConcreteObject() {
        XCTAssertNotNil(note("Сделай архив проекта", "Архив создан, лежит в artifacts."))
    }

    // MARK: - Answers that are not claims

    func testExplanationWithActionWordsIsNotFlagged() {
        // The exact shape that produced the spurious note: a question about how
        // something works, answered with an explanation full of "создаётся"/"готово".
        let question = "Как в Swift создаётся файл и когда он готов к записи?"
        let answer = """
        Файл создаётся через `FileManager.default.createFile(atPath:contents:)` или \
        `Data.write(to:)`. Готово к записи означает, что дескриптор открыт и каталог \
        существует; если каталога нет, запись упадёт с ошибкой. Обычно достаточно \
        `try data.write(to: url, options: .atomic)` — атомарная запись сама создаёт \
        временный файл рядом и переименовывает его.
        """
        XCTAssertNil(note(question, answer))
    }

    func testClaimBuriedInLongAnswerIsIgnored() {
        let question = "Создай файл и объясни, как работает FileManager"
        let long = String(repeating: "Объяснение того, как устроена запись в файл. ", count: 30)
            + " Я создал файл, но это было в примере кода."
        XCTAssertNil(note(question, long), "a claim deep inside an explanation is not a summary")
    }

    func testActionWordInAQuestionIsNotARequest() {
        XCTAssertNil(note("А если я удалю файл, что произойдёт?", "Готово — но это только теория."))
    }

    func testPlainAnswerWithoutClaimIsNotFlagged() {
        XCTAssertNil(note("Создай файл", "Файл можно создать через FileManager."))
    }

    func testEmptyAnswerIsNotFlagged() {
        XCTAssertNil(note("Создай файл", ""))
    }

    // MARK: - Building blocks

    func testRequestDetectionIsAnchored() {
        XCTAssertTrue(FalseSuccessGuard.looksLikeActionRequest("Создай файл note.txt"))
        XCTAssertTrue(FalseSuccessGuard.looksLikeActionRequest("Так, удали папку build"))
        XCTAssertTrue(FalseSuccessGuard.looksLikeActionRequest("Можешь добавить сюда тест?"))
        XCTAssertTrue(FalseSuccessGuard.looksLikeActionRequest("Проверяй сайт каждый час"))
        XCTAssertFalse(FalseSuccessGuard.looksLikeActionRequest("Как создаётся файл?"))
        XCTAssertFalse(FalseSuccessGuard.looksLikeActionRequest("Что такое удаление файла"))
    }

}
