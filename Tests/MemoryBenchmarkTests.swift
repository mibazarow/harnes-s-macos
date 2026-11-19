import XCTest
@testable import Harness

/// B13: a number for memory quality, so a change to ranking or filters can be judged.
///
/// Without it "the search got better" is a feeling. The benchmark is deterministic: a
/// fixed corpus, each record's own text used as the query, and recall@1 / recall@5.
final class MemoryBenchmarkTests: XCTestCase {
    /// Distinct on purpose: `add` merges near-duplicates, and a corpus of copies would
    /// measure the deduplicator instead of the search.
    private static let corpus: [String] = [
        "Сервер альфа крутится на Ubuntu двадцать четыре ноль четыре и обновляется по вторникам",
        "Почта живёт на Fastmail, синхронизация с телефоном через IMAP",
        "Календарь ведётся в Apple Calendar, две подписки: работа и семья",
        "Роутер Keenetic стоит в коридоре за шкафом, пароль в секретах",
        "Принтер Brother подключён по воздуху, драйвер ставится из App Store",
        "Сканер Epson лежит в нижнем ящике стола и редко используется",
        "Клавиатура механическая с коричневыми свитчами, раскладка русская",
        "Мышь вертикальная от Logitech, третья за четыре года",
        "Монитор тридцать четыре дюйма с изогнутым экраном и USB-хабом",
        "Наушники закрытые, чтобы работать в шумном офисе",
        "Проект Харнес собирается через xcodebuild, не через make",
        "Релиз выкладывается тегом и заметкой в GitHub Releases",
        "Сертификат Developer ID действует до восемнадцатого декабря",
        "Нотаризация запускается через notarytool с профилем HARNESS_NOTARY",
        "Память приложения хранится в GRDB и мигрирует только добавлением колонок",
        "Контекст модели сжимается в саммари, старые сообщения остаются в базе",
        "Провайдер Ollama работает локально и не требует ключа",
        "Прокси включается только для внешних запросов, локальные идут напрямую",
        "Бэкап базы делается копированием файла harness.db раз в неделю",
        "Стиль ответа: коротко, по делу, без вступлений и извинений"
    ]

    private func seededCorpus() async throws -> (MemoryService, [MemoryItem]) {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        var items: [MemoryItem] = []
        for text in Self.corpus {
            items.append(try await memory.add(text, area: "fact"))
        }
        return (memory, items)
    }

    func testRecallIsAtLeastTheAgreedFloor() async throws {
        let (memory, items) = try await seededCorpus()

        var top1 = 0
        var top5 = 0
        for item in items {
            // First 300 characters, like the reference benchmark: a question made from
            // the record's own words.
            let query = String(item.content.prefix(300))
            let hits = try await memory.search(query, limit: 5)
            if hits.first?.id == item.id { top1 += 1 }
            if hits.prefix(5).contains(where: { $0.id == item.id }) { top5 += 1 }
        }

        let recall1 = Double(top1) / Double(items.count)
        let recall5 = Double(top5) / Double(items.count)
        print("memory benchmark: recall@1=\(recall1) recall@5=\(recall5) n=\(items.count)")

        XCTAssertGreaterThanOrEqual(recall1, 0.85, "recall@1 упал: \(recall1)")
        XCTAssertGreaterThanOrEqual(recall5, 0.95, "recall@5 упал: \(recall5)")
    }

    func testEveryRecordIsFoundByItsOwnText() async throws {
        let (memory, items) = try await seededCorpus()
        for item in items {
            let hits = try await memory.search(item.content, limit: 5)
            XCTAssertTrue(
                hits.contains { $0.id == item.id },
                "запись #\(item.id) не находится по своему тексту"
            )
        }
    }

    func testShortNoiseIsNotInTheCorpus() {
        // The reference benchmark drops items under 15 letters before measuring; the
        // corpus here is prose, and a one-word record would make recall meaningless.
        for text in Self.corpus {
            XCTAssertGreaterThan(text.count, 15, text)
        }
    }
}
