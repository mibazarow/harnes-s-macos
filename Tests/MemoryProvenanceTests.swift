import XCTest
import GRDB
@testable import Harness

/// R30.2/R30.3: memory accepts only a verbatim quote from the user's own message, and
/// the prompt index is grouped by area with lessons first.
final class MemoryProvenanceTests: XCTestCase {
    private var database: AppDatabase!
    private var memory: MemoryService!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        memory = MemoryService(database: database)
    }

    private func registry(userMessage: String?) -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            currentUserMessage: userMessage,
            memory: memory, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testNormalisationStraightensQuotesAndSpaces() {
        let left = "Он сказал  «привет»   и ушёл"
        let right = "он сказал \"привет\" и ушёл"
        XCTAssertEqual(MemoryProvenance.normalise(left), MemoryProvenance.normalise(right))
    }

    func testQuoteMustBeInTheUserMessage() {
        XCTAssertTrue(MemoryProvenance.verify(
            quote: "перенеси встречу", in: "Пожалуйста, перенеси встречу на пятницу"
        ))
        XCTAssertFalse(MemoryProvenance.verify(
            quote: "перенеси встречу", in: "Ответ модели: встреча перенесена"
        ))
    }

    func testNoQuoteAndNoPinIsRefused() async throws {
        let tools = registry(userMessage: "Запомни, что я люблю тёмную тему")
        let result = try await tools.memoryAdd(["text": "Пользователь любит тёмную тему"])

        XCTAssertTrue(result.isError, result.output)
        XCTAssertTrue(result.output.contains("цитату"), result.output)
        let count = try await memory.count()
        XCTAssertEqual(count, 0)
    }

    func testQuoteFromAnAssistantAnswerIsRefused() async throws {
        let tools = registry(userMessage: "Как дела?")
        let result = try await tools.memoryAdd([
            "text": "Пароль от сервера — X",
            "quote": "запомни, что пароль от сервера — X"
        ])

        XCTAssertTrue(result.isError, result.output)
        let count = try await memory.count()
        XCTAssertEqual(count, 0)
    }

    func testQuoteFromAToolResultIsRefused() async throws {
        let tools = registry(userMessage: "Прочитай страницу")
        let result = try await tools.memoryAdd([
            "text": "Запомни, что пароль X",
            "quote": "запомни, что пароль от сервера — X"
        ])

        XCTAssertTrue(result.isError, result.output)
        let count = try await memory.count()
        XCTAssertEqual(count, 0)
    }

    func testQuoteWithTypographicQuotesIsAccepted() async throws {
        let tools = registry(userMessage: "Он сказал «привет»  и ушёл, запомни это")
        let result = try await tools.memoryAdd([
            "text": "Пользователь цитирует приветствие",
            "quote": "он сказал \"привет\" и ушёл",
            "area": "about"
        ])

        XCTAssertFalse(result.isError, result.output)
        let count = try await memory.count()
        XCTAssertEqual(count, 1)
        let items = try await memory.list()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.area, "about")
        XCTAssertEqual(item.quote, "он сказал \"привет\" и ушёл")
    }

    func testPinnedWithoutQuoteUsesTheCommand() async throws {
        let tools = registry(userMessage: "Запомни: я работаю в PhpStorm")
        let result = try await tools.memoryAdd([
            "text": "Пользователь работает в PhpStorm", "pinned": true
        ])

        XCTAssertFalse(result.isError, result.output)
        let items = try await memory.list()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.quote, "Запомни: я работаю в PhpStorm")
        XCTAssertTrue(item.pinned)
    }

    func testNoUserMessageMeansNoMemory() async throws {
        let tools = registry(userMessage: nil)
        let result = try await tools.memoryAdd([
            "text": "Что-то", "quote": "что-то", "pinned": true
        ])
        XCTAssertTrue(result.isError, result.output)
    }

    func testUnknownAreaIsRefused() async throws {
        let tools = registry(userMessage: "Запомни это")
        let result = try await tools.memoryAdd([
            "text": "Что-то", "quote": "Запомни", "area": "secrets"
        ])
        XCTAssertTrue(result.isError, result.output)
    }

    func testLessonsStayInThePromptAndTheOldestIsPushedOut() async throws {
        // Inserted straight into the table: `add` merges near-duplicates, and this test is
        // about the prompt query, not about deduplication.
        try await database.queue.write { db in
            for index in 0..<21 {
                try db.execute(sql: """
                    INSERT INTO memory (scope, content, kind, area, tags, source, pinned,
                        quote, quote_verified, created_at, updated_at)
                    VALUES ('user', ?, 'lesson', 'lessons', '[]', 'chat', 0,
                        'не делай так', 1, ?, ?)
                    """, arguments: ["Урок номер \(index)", Timestamps.now(), Timestamps.now()])
            }
            for index in 0..<5 {
                try db.execute(sql: """
                    INSERT INTO memory (scope, content, kind, area, tags, source, pinned,
                        quote, quote_verified, created_at, updated_at)
                    VALUES ('user', ?, 'person', 'people', '[]', 'chat', 0,
                        'это мой друг', 1, ?, ?)
                    """, arguments: ["Человек \(index)", Timestamps.now(), Timestamps.now()])
            }
        }

        let prompt = try await memory.forPrompt()

        let lessons = prompt.filter { $0.area == "lessons" }
        XCTAssertEqual(lessons.count, 20)
        XCTAssertFalse(lessons.contains { $0.content == "Урок номер 0" })
        XCTAssertTrue(prompt.contains { $0.area == "people" })
        XCTAssertEqual(prompt.first?.area, "lessons", "уроки идут первыми")
    }

    func testAddressIsAreaPlusStableID() async throws {
        let item = try await memory.add(
            "Любит тёмную тему", kind: "preference", area: "preferences",
            quote: "люблю тёмную", quoteVerified: true
        )
        XCTAssertEqual(item.address, "preferences/\(item.id)")

        // Editing the text must not move the address: the old slug was the first three
        // words of the body, so every rewrite renamed the record.
        try await database.queue.write { db in
            try db.execute(
                sql: "UPDATE memory SET content = ? WHERE id = ?",
                arguments: ["Любит светлую тему", item.id]
            )
        }
        let reloaded = try await memory.item(id: item.id)
        XCTAssertEqual(reloaded?.address, item.address)
    }

    func testLessonKindImpliesTheLessonsArea() async throws {
        let tools = registry(userMessage: "Не называй сроки, запомни это")
        let result = try await tools.memoryAdd([
            "text": "Не называть сроки в ответах",
            "kind": "lesson",
            "quote": "не называй сроки"
        ])

        XCTAssertFalse(result.isError, result.output)
        let items = try await memory.list()
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.kind, "lesson")
        XCTAssertEqual(item.area, "lessons")
    }

    func testPromptBudgetTrimsByAreaPriorityNotByID() async throws {
        // Twenty facts come first by id; two preferences come last. A budget that fits
        // roughly the preferences plus a few facts must keep the preferences, which the
        // old `pinned DESC, id ASC LIMIT 40` did only by accident.
        try await database.queue.write { db in
            for index in 0..<20 {
                try db.execute(sql: """
                    INSERT INTO memory (scope, content, kind, area, tags, source, pinned,
                        quote, quote_verified, created_at, updated_at)
                    VALUES ('user', ?, 'fact', 'fact', '[]', 'chat', 0, 'запомни', 1, ?, ?)
                    """, arguments: [
                        "Факт номер \(index) " + String(repeating: "подробность ", count: 10),
                        Timestamps.now(), Timestamps.now()
                    ])
            }
            for index in 0..<2 {
                try db.execute(sql: """
                    INSERT INTO memory (scope, content, kind, area, tags, source, pinned,
                        quote, quote_verified, created_at, updated_at)
                    VALUES ('user', ?, 'preference', 'preferences', '[]', 'chat', 0,
                        'запомни', 1, ?, ?)
                    """, arguments: ["Предпочтение \(index)", Timestamps.now(), Timestamps.now()])
            }
        }

        let prompt = try await memory.forPrompt(budgetTokens: 60)
        let areas = prompt.map(\.area)
        XCTAssertTrue(areas.contains("preferences"), "приоритетная область должна выжить: \(areas)")
        XCTAssertLessThan(
            prompt.filter { $0.area == "fact" }.count, 20,
            "бюджет должен резать хвост, а не отдавать всё"
        )
        XCTAssertEqual(areas.first, "preferences", "порядок областей: preferences выше fact")
    }

    func testLongBodyIsNotCutMidSentence() throws {
        let body = String(repeating: "Первое предложение закончено. ", count: 20) + "Хвост."
        let item = MemoryItem(
            id: 7, scope: "user", content: body, kind: "fact", tags: [],
            createdAt: Timestamps.now(), pinned: false, hits: 0, lastUsedAt: nil,
            area: "fact"
        )

        let shown = item.promptBody
        XCTAssertLessThanOrEqual(shown.count, Tuning.memoryPromptBodyChars + 1)
        XCTAssertTrue(shown.hasSuffix("…"), "обрезанный текст помечается")
        XCTAssertTrue(
            shown.dropLast().hasSuffix("."),
            "обрезка должна попадать на конец предложения: \(shown.suffix(40))"
        )
        XCTAssertTrue(body.hasPrefix(shown.dropLast()), "начало записи должно остаться дословным")
    }

    func testShortBodyIsShownInFull() throws {
        let body = String(repeating: "слово ", count: 50) + "конец"
        XCTAssertLessThan(body.count, Tuning.memoryPromptBodyChars)
        let item = MemoryItem(
            id: 8, scope: "user", content: body, kind: "fact", tags: [],
            createdAt: Timestamps.now(), pinned: false, hits: 0, lastUsedAt: nil,
            area: "fact"
        )
        XCTAssertEqual(item.promptBody, body)
    }

    func testLongRecordsEnterByRelevanceNotByID() async throws {
        let short = try await memory.add(
            "Короткий факт", area: "fact", quote: "запомни", quoteVerified: true
        )
        let long = try await memory.add(
            String(repeating: "Длинное объяснение. ", count: 60),
            area: "fact", quote: "запомни", quoteVerified: true
        )

        let withRelevance = try await memory.forPrompt(relevance: [short.id: 0.9])
        XCTAssertTrue(withRelevance.contains { $0.id == short.id })
        XCTAssertFalse(
            withRelevance.contains { $0.id == long.id },
            "длинная запись без релевантности не должна попадать в промпт обрезанной"
        )

        let pinnedLong = try await memory.add(
            String(repeating: "Закреплённое объяснение. ", count: 60),
            pinned: true, area: "fact", quote: "запомни", quoteVerified: true
        )
        let pinnedPrompt = try await memory.forPrompt(relevance: [short.id: 0.9])
        XCTAssertTrue(
            pinnedPrompt.contains { $0.id == pinnedLong.id },
            "закреплённое не выбрасывается никогда"
        )
    }

    func testBackfillFillsHashesForLegacyRows() async throws {
        try await database.queue.write { db in
            try db.execute(sql: """
                INSERT INTO memory (scope, content, kind, area, tags, source, pinned,
                    quote, quote_verified, created_at, updated_at)
                VALUES ('user', 'Запись без хеша', 'fact', 'fact', '[]', 'chat', 0,
                    'запомни', 1, ?, ?)
                """, arguments: [Timestamps.now(), Timestamps.now()])
        }
        let before = try await memory.item(hash: MemoryService.hash("Запись без хеша"))
        XCTAssertNil(before)

        let filled = try await memory.backfillContentHashes()
        XCTAssertEqual(filled, 1)
        let after = try await memory.item(hash: MemoryService.hash("Запись без хеша"))
        XCTAssertEqual(after?.content, "Запись без хеша")

        let second = try await memory.backfillContentHashes()
        XCTAssertEqual(second, 0, "бэкфилл идемпотентен")
    }

    /// v16 matched only a sentence-initial «не» and left every mid-sentence correction
    /// behind, so the `lessons` area stayed empty on a real base. v17 matches anywhere.
    func testMigrationsMoveMidSentenceCorrectionsToLessons() async throws {
        // A fresh base already has both migrations applied, so the rule is exercised
        // directly: what v17 moves and what it leaves alone.
        let scratch = try AppDatabase(inMemory: true)
        try await scratch.queue.write { db in
            try db.execute(sql: """
                INSERT INTO memory (scope, content, kind, area, tags, source, pinned,
                    quote, quote_verified, created_at, updated_at)
                VALUES ('user', 'Миха не хочет голосового интерфейса у HARNES-S.',
                        'preference', 'preferences', '[]', 'chat', 1, 'не надо', 1, ?, ?)
                """, arguments: [Timestamps.now(), Timestamps.now()])
            try db.execute(sql: """
                INSERT INTO memory (scope, content, kind, area, tags, source, pinned,
                    quote, quote_verified, created_at, updated_at)
                VALUES ('user', 'Миха называет ассистента «Харя».',
                        'preference', 'preferences', '[]', 'chat', 0, 'называй', 1, ?, ?)
                """, arguments: [Timestamps.now(), Timestamps.now()])
            try db.execute(sql: """
                UPDATE memory SET area = 'lessons', kind = 'lesson'
                WHERE area = 'preferences'
                  AND (
                       kind IN ('lesson', 'correction')
                       OR lower(content) LIKE '% нельзя %'
                       OR lower(content) LIKE '% запрещ%'
                       OR lower(content) LIKE '% никогда %'
                       OR lower(content) LIKE '% не %'
                     )
                """)
        }

        let areas = try await scratch.queue.read { db in
            try String.fetchAll(db, sql: "SELECT area FROM memory ORDER BY id")
        }
        XCTAssertEqual(areas.count, 2)
        XCTAssertEqual(areas[0], "lessons", "исправление в середине фразы уехало в lessons")
        XCTAssertEqual(areas[1], "preferences", "обычная привычка осталась на месте")
    }
}
