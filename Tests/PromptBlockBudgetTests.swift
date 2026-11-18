import XCTest
@testable import Harness

/// R34.1: each always-on block has a ceiling and says what it dropped.
final class PromptBlockBudgetTests: XCTestCase {
    func testShortTextPassesUnchanged() {
        let (text, omitted) = PromptBlockBudget.clip("коротко", limit: 100)
        XCTAssertEqual(text, "коротко")
        XCTAssertEqual(omitted, 0)
    }

    func testLongTextIsCutAtALineBoundary() {
        let text = (0..<50).map { "строка \($0)" }.joined(separator: "\n")
        let (kept, omitted) = PromptBlockBudget.clip(text, limit: 120)
        XCTAssertLessThanOrEqual(kept.count, 120)
        XCTAssertGreaterThan(omitted, 0)
        XCTAssertFalse(kept.hasSuffix("стр"), "обрезка не должна ломать слово пополам")
    }

    func testOmittedLineNamesTheNumber() {
        XCTAssertEqual(PromptBlockBudget.omittedLine(42), "…ещё 42 символов не показано")
        XCTAssertEqual(
            PromptBlockBudget.omittedLine(3, noun: "записей"),
            "…ещё 3 записей не показано"
        )
    }

    func testListIsClippedByEntriesNotCharacters() {
        let entries = (0..<20).map { "навык номер \($0)" }
        let (text, omitted) = PromptBlockBudget.clipList(entries, limit: 60)
        XCTAssertGreaterThan(omitted, 0)
        for line in text.split(separator: "\n") {
            XCTAssertFalse(line.hasSuffix("ном"), "половина пункта хуже, чем на один меньше")
        }
    }

    func testListKeepsAtLeastOneEntry() {
        let (text, omitted) = PromptBlockBudget.clipList(["длинный-навык"], limit: 1)
        XCTAssertFalse(text.isEmpty)
        XCTAssertEqual(omitted, 0)
    }

    func testMemoryPromptReportsOverflow() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let topics = [
            "Сервер", "Почта", "Календарь", "Роутер", "Принтер", "Сканер", "Клавиатура",
            "Мышь", "Монитор", "Наушники", "Камера", "Микрофон", "Колонки", "Диск",
            "Флешка", "Ноутбук", "Телефон", "Планшет", "Часы", "Лампа",
            "Стол", "Кресло", "Окно", "Дверь", "Кухня", "Ванная", "Балкон", "Гараж",
            "Машина", "Велосипед", "Самокат", "Рюкзак", "Куртка", "Ботинки", "Шапка",
            "Очки", "Зонт", "Кошелёк", "Ключи", "Паспорт"
        ]
        for (index, topic) in topics.enumerated() {
            _ = try await memory.add("\(topic) заметка\(index)")
        }
        let selection = try await memory.forPromptWithOverflow(budgetTokens: 60)
        XCTAssertFalse(selection.items.isEmpty)
        XCTAssertGreaterThan(selection.omitted, 0, "переполнение должно быть названо числом")
    }

    func testMemoryPromptWithoutOverflowReportsZero() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        _ = try await memory.add("Один короткий факт")
        let selection = try await memory.forPromptWithOverflow()
        XCTAssertEqual(selection.items.count, 1)
        XCTAssertEqual(selection.omitted, 0)
    }
}
