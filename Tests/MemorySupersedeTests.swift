import XCTest
import GRDB
@testable import Harness

/// R33.2: an outdated fact is replaced, not erased. The old row stays by id.
final class MemorySupersedeTests: XCTestCase {
    func testTwentyLabelledQueriesPreserveTopThreeInDisplay() async throws {
        let memory = MemoryService(database: try AppDatabase(inMemory: true))
        let topics = ["Ubuntu", "Fastmail", "Keenetic", "Brother", "Epson",
                      "Logitech", "Nordwand", "PostgreSQL", "Redis", "Docker",
                      "Swift", "Kotlin", "Rust", "Python", "SQLite",
                      "Grafana", "Prometheus", "Tailscale", "Synology", "Obsidian"]
        var expected: [(String, Int64)] = []
        for topic in topics {
            let item = try await memory.add("\(topic): отдельная настройка рабочего окружения", contentHash: UUID().uuidString)
            expected.append((topic, item.id))
        }
        for (query, id) in expected {
            let hits = try await memory.search(query)
            let top = Array(hits.prefix(3))
            XCTAssertTrue(top.contains { $0.id == id }, "Baseline top-3: \(query)")
            let rendered = MemoryContradiction.groupedSearchText(top)
            XCTAssertTrue(rendered.contains("#\(id) ["), "Display must retain top-3: \(query)")
        }
    }

    func testReportUsesStoredEmbeddingsWithoutChangingUsage() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let embeddings = EmbeddingsService(database: database)
        let first = try await memory.add("Архивы размещены на удалённом хранилище")
        let second = try await memory.add("Архивы размещены на удалённом хранилище данных")
        for id in [first.id, second.id] {
            try await embeddings.store(refKind: "memory", refID: String(id),
                                       vector: .init(values: [1, 0, 0], model: "fixture"))
        }
        let before = try await memory.list()
        let report = try await memory.maintenanceReport()
        XCTAssertTrue(report.contains("Точных дублей: 1"), report)
        XCTAssertTrue(report.contains("#\(first.id)"))
        XCTAssertTrue(report.contains("#\(second.id)"))
        let after = try await memory.list()
        XCTAssertEqual(before, after)
    }

    func testReportSeparatesExactDuplicatesFromLikelyPairs() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)
        let embeddings = EmbeddingsService(database: database)
        // #129/#140: cosine 0.937 but Jaccard 0.125 — a restatement, not a duplicate.
        let restated = try await memory.add("Пользователь сам удалит TASK_AGENT_FIXES.md")
        let restatement = try await memory.add("Упоминания TASK_AGENT_FIXES.md нужно удалить из проекта")
        // #131/#188: cosine 0.869, Jaccard 0.692 — the middle band that used to be lost.
        let likelyA = try await memory.add("Графовая память Barbot хранит связи между заметками проекта")
        let likelyB = try await memory.add("Графовая память Barbot хранит связи между заметками")
        // A true duplicate: same wording, so both cosine and Jaccard are high.
        let duplicateA = try await memory.add("Резервные копии сервера хранятся в Казани")
        let duplicateB = try await memory.add("Резервные копии сервера хранятся в городе Казани")
        let vectors: [(Int64, [Float])] = [
            (restated.id, [1, 0, 0]),
            (restatement.id, [0.937, 0.349, 0]),
            (likelyA.id, [0, 1, 0]),
            (likelyB.id, [0, 0.869, 0.494]),
            (duplicateA.id, [0, 0, 1]),
            (duplicateB.id, [0, 0, 1])
        ]
        for (id, values) in vectors {
            try await embeddings.store(refKind: "memory", refID: String(id),
                                       vector: .init(values: values, model: "fixture"))
        }
        let report = try await memory.maintenanceReport()
        let exact = try XCTUnwrap(report.components(separatedBy: "## Похожие, проверь").first)
        let likelySection = try XCTUnwrap(report.components(separatedBy: "## Похожие, проверь").last)
        let likely = try XCTUnwrap(likelySection.components(separatedBy: "## Противоречия").first)
        XCTAssertTrue(exact.contains("#\(duplicateA.id)"), "косинус 1.0 + жаккар 1.0 — точный дубль")
        XCTAssertTrue(exact.contains("#\(duplicateB.id)"))
        XCTAssertFalse(exact.contains("#\(restated.id)"), "0.937 без жаккара — не точный дубль")
        XCTAssertFalse(exact.contains("#\(restatement.id)"))
        XCTAssertTrue(likely.contains("#\(likelyA.id)"), "0.869 + жаккар 0.69 — средняя зона")
        XCTAssertTrue(likely.contains("#\(likelyB.id)"))
        XCTAssertFalse(likely.contains("#\(restated.id)"), "жаккар 0.125 ниже 0.4")
    }

    func testReportFileIsPrivateAndReplaceable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try MemoryService.saveReport("first", directory: directory, date: date)
        _ = try MemoryService.saveReport("second", directory: directory, date: date)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "second")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testMaintenanceReportIsDeterministicAndReadOnly() async throws {
        let memory = MemoryService(database: try AppDatabase(inMemory: true))
        _ = try await memory.add("Сервер alpha можно выключать ночью")
        _ = try await memory.add("Сервер alpha нельзя выключать ночью", supersedesID: nil)
        let before = try await memory.list()
        let first = try await memory.maintenanceReport()
        let second = try await memory.maintenanceReport()
        let after = try await memory.list()
        XCTAssertEqual(first, second)
        XCTAssertEqual(before, after)
        XCTAssertTrue(first.contains("Противоречия"))
        XCTAssertTrue(first.contains("Непрочитанные"))
    }

    func testSearchDisplayGroupsWithoutDiscardingFactsOrContradictions() {
        func item(_ id: Int64, _ text: String) -> MemoryItem {
            MemoryItem(id: id, scope: "user", content: text, kind: "fact", tags: [],
                       createdAt: "2026-11-20", pinned: false, hits: 1, lastUsedAt: nil)
        }
        let first = item(1, "Сервер alpha использует Ubuntu для всех рабочих задач")
        let similar = item(2, "Сервер alpha использует Ubuntu для всех рабочих задач ежедневно")
        let output = MemoryContradiction.groupedSearchText([first, similar])
        XCTAssertTrue(output.contains("Близкие записи"))
        XCTAssertTrue(output.contains(first.content))
        XCTAssertTrue(output.contains(similar.content))
        let conflict = MemoryContradiction.groupedSearchText([
            item(3, "Сервер alpha можно выключать ночью"),
            item(4, "Сервер alpha нельзя выключать ночью")
        ])
        XCTAssertFalse(conflict.contains("Близкие записи"))
        XCTAssertTrue(conflict.contains("противоречит"))
    }

    func testUnreadFactsStaySearchableButDoNotConsumePromptBudget() async throws {
        let memory = MemoryService(database: try AppDatabase(inMemory: true))
        let fact = try await memory.add("Копии сервера хранятся в Казани")
        let pinned = try await memory.add("Проверять резервные копии еженедельно", pinned: true)
        let before = try await memory.forPrompt()
        XCTAssertFalse(before.contains { $0.id == fact.id })
        XCTAssertTrue(before.contains { $0.id == pinned.id })
        let found = try await memory.search("Казани")
        XCTAssertTrue(found.contains { $0.id == fact.id })
        try await memory.touch(ids: [fact.id])
        let after = try await memory.forPrompt()
        XCTAssertTrue(after.contains { $0.id == fact.id })
    }

    func testMergeRollsBackWhenArchivingFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database, backupDirectory: directory)
        let first = try await memory.add("Первичный сервер расположен в Москве")
        let second = try await memory.add("Резервные копии отправляются в Казань")
        try await database.queue.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_archive BEFORE UPDATE OF archived ON memory
                BEGIN SELECT RAISE(ABORT, 'archive unavailable'); END
                """)
        }
        do {
            _ = try await memory.merge(ids: [first.id, second.id], into: "Инфраструктура")
            XCTFail("The entire transaction must fail")
        } catch {}
        let count = try await memory.count()
        let active = try await memory.list()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(Set(active.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testMergeDoesNotWriteWithoutBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocked = directory.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blocked)
        let memory = MemoryService(database: try AppDatabase(inMemory: true), backupDirectory: blocked)
        let first = try await memory.add("Первичный сервер расположен в Москве")
        let second = try await memory.add("Резервные копии отправляются в Казань")
        do {
            _ = try await memory.merge(ids: [first.id, second.id], into: "Инфраструктура")
            XCTFail("Backup failure must prevent consolidation")
        } catch {}
        let count = try await memory.count()
        let active = try await memory.list()
        XCTAssertEqual(count, 2)
        XCTAssertEqual(active.count, 2)
    }

    func testMergePreservesSourcesAndCreatesBackup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database, backupDirectory: directory)
        let first = try await memory.add("Сервер alpha расположен в Москве")
        let second = try await memory.add("Резервная копия хранится в Казани")
        let merged = try await memory.merge(ids: [first.id, second.id], into: "Инфраструктура: Москва и Казань")
        let active = try await memory.list()
        XCTAssertEqual(active.map(\.id), [merged.id])
        let old = try await memory.item(id: first.id)
        XCTAssertEqual(old?.content, first.content)
        XCTAssertEqual(old?.mergedInto, merged.id)
        XCTAssertEqual(old?.archived, true)
        let searchResolved = await memory.items(ids: [first.id, second.id, merged.id])
        XCTAssertEqual(Set(searchResolved.keys), Set([merged.id]))
        let stats = try await memory.stats()
        XCTAssertEqual(stats.archived, 2)
        XCTAssertEqual(stats.total, 1)
        let count = try await memory.count()
        XCTAssertEqual(count, 3)
        XCTAssertTrue(merged.content.contains("#\(first.id)"))
        let backups = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(backups.count, 1)
        let restored = try AppDatabase(path: XCTUnwrap(backups.first))
        let backupCount = try await MemoryService(database: restored).count()
        XCTAssertEqual(backupCount, 2)
    }

    func testMergeRejectsPinnedWithoutPermission() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let memory = MemoryService(database: try AppDatabase(inMemory: true), backupDirectory: directory)
        let first = try await memory.add("Не менять закреплённое правило", pinned: true)
        let second = try await memory.add("Отдельный факт про резервирование")
        do {
            _ = try await memory.merge(ids: [first.id, second.id], into: "Сводка")
            XCTFail("Pinned sources require explicit permission")
        } catch {}
        let active = try await memory.list()
        XCTAssertEqual(active.count, 2)
    }

    func testNewFactReplacesOldInSearchButOldStaysByID() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)

        let old = try await memory.add(
            "Сервер работает на Ubuntu 22.04", area: "fact", quote: "сервер на 22.04",
            quoteVerified: true
        )
        let new = try await memory.add(
            "Сервер работает на Ubuntu 24.04", area: "fact", quote: "сервер на 24.04",
            quoteVerified: true, supersedesID: old.id
        )

        let hits = try await memory.search("сервер ubuntu")
        XCTAssertTrue(hits.contains { $0.id == new.id }, "новый факт должен находиться")
        XCTAssertFalse(hits.contains { $0.id == old.id }, "старый факт не должен выдаваться")

        let byID = try await memory.item(id: old.id)
        XCTAssertEqual(byID?.content, "Сервер работает на Ubuntu 22.04")
    }

    func testPromptCarriesOnlyTheCurrentFact() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)

        let old = try await memory.add("Встречи по средам", area: "routines", quote: "среды")
        _ = try await memory.add(
            "Встречи по четвергам", area: "routines", quote: "четверги",
            quoteVerified: true, supersedesID: old.id
        )

        let active = try await memory.list()
        try await memory.touch(ids: active.map(\.id))

        let prompt = try await memory.forPrompt()
        XCTAssertTrue(prompt.contains { $0.content.contains("четвергам") })
        XCTAssertFalse(prompt.contains { $0.content.contains("средам") })
    }

    func testListHidesSupersededButCountsRows() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)

        let old = try await memory.add("Старый адрес", area: "fact", quote: "старый")
        _ = try await memory.add(
            "Новый адрес", area: "fact", quote: "новый", supersedesID: old.id
        )

        let active = try await memory.list()
        XCTAssertEqual(active.count, 1)
        XCTAssertEqual(active.first?.content, "Новый адрес")
        let total = try await memory.count()
        XCTAssertEqual(total, 2, "обе строки остаются на диске")
    }

    func testSupersededRecordIsNotMergedIntoTheNewOne() async throws {
        let database = try AppDatabase(inMemory: true)
        let memory = MemoryService(database: database)

        let old = try await memory.add("Любимый редактор Sublime Text", area: "preferences")
        let replacement = try await memory.add(
            "Любимый редактор Sublime Text", area: "preferences", supersedesID: old.id
        )
        XCTAssertNotEqual(replacement.id, old.id, "замена — новая строка, а не правка старой")
    }
}
