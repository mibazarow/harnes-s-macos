import XCTest
@testable import Harness

final class SkillStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-skills-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func skill(_ name: String, summary: String = "", triggers: [String] = [], allowed: [String] = [], body: String = "Инструкции.") throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var front = "---\nname: \(name)\n"
        if !summary.isEmpty { front += "description: \(summary)\n" }
        if !triggers.isEmpty { front += "triggers: [\(triggers.joined(separator: ", "))]\n" }
        if !allowed.isEmpty { front += "allowed-tools: [\(allowed.joined(separator: ", "))]\n" }
        front += "---\n\n\(body)\n"
        try front.write(to: directory.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        return directory
    }

    private func service() -> SkillsService {
        SkillsService(userDirectory: root, builtinDirectory: nil)
    }

    func testLongBodyIsPaginatedWithAnOffset() async throws {
        let long = String(repeating: "a", count: 70_000)
        _ = try skill("long", body: long)
        let service = service()

        let first = try await service.read(name: "long")
        XCTAssertTrue(first.text.contains("тело обрезано"), first.text.suffix(200).description)
        XCTAssertNotNil(first.nextOffset)

        let second = try await service.read(name: "long", offset: first.nextOffset ?? 0)
        XCTAssertFalse(second.text.contains("тело обрезано"))
    }

    func testBundledFileIsReadableAndTraversalIsRefused() async throws {
        let directory = try skill("files")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("references"), withIntermediateDirectories: true)
        try "структура отчёта".write(
            to: directory.appendingPathComponent("references/report.md"), atomically: true, encoding: .utf8
        )
        let service = service()

        let reading = try await service.read(name: "files", file: "references/report.md")
        XCTAssertTrue(reading.text.contains("структура отчёта"), reading.text)

        do {
            _ = try await service.read(name: "files", file: "../outside.md")
            XCTFail("выход за пределы скилла должен быть запрещён")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("пределы"), error.localizedDescription)
        }
    }

    func testFileListIsSortedAndTruncatedWithANote() async throws {
        let directory = try skill("many")
        for index in stride(from: 69, through: 0, by: -1) {
            try "x".write(
                to: directory.appendingPathComponent(String(format: "f%02d.txt", index)),
                atomically: true, encoding: .utf8
            )
        }
        let service = service()

        let reading = try await service.read(name: "many")
        XCTAssertTrue(reading.text.contains("- f00.txt"), reading.text)
        XCTAssertTrue(reading.text.contains("ещё 10 файлов"), reading.text)
        let last = try XCTUnwrap(reading.text.range(of: "f59.txt"))
        let first = try XCTUnwrap(reading.text.range(of: "f00.txt"))
        XCTAssertLessThan(first.lowerBound, last.lowerBound, "файлы должны идти по алфавиту")
        XCTAssertFalse(reading.text.contains("- f69.txt"), "за лимитом 60 файл не печатается")
    }

    func testAllowedToolsAreEnforcedByTheRegistry() async throws {
        _ = try skill("reader", allowed: ["fs_read"])
        let service = service()
        let scope = ActiveSkillScope()
        let tool = ToolRegistry(
            workspace: root, memory: nil, embeddings: nil, secrets: nil,
            skills: service, mcp: nil, skillScope: scope
        )

        let read = await tool.execute(ToolCall(id: "1", name: "skill_read", arguments: #"{"name":"reader"}"#))
        XCTAssertFalse(read.isError, read.output)
        let active = await scope.activeSkill
        XCTAssertEqual(active, "reader")

        let blocked = await tool.execute(ToolCall(id: "2", name: "bash", arguments: #"{"command":"true"}"#))
        XCTAssertTrue(blocked.isError)
        XCTAssertTrue(blocked.output.contains("не разрешён активным скиллом"), blocked.output)

        // Meta tools stay available: otherwise the agent cannot recover.
        let meta = await tool.execute(ToolCall(id: "3", name: "todo_read", arguments: "{}"))
        XCTAssertFalse(meta.output.contains("не разрешён активным скиллом"), meta.output)
    }

    func testReadingASkillWithoutRestrictionsClearsTheScope() async throws {
        _ = try skill("reader", allowed: ["fs_read"])
        _ = try skill("free")
        let service = service()
        let scope = ActiveSkillScope()
        let tool = ToolRegistry(
            workspace: root, memory: nil, embeddings: nil, secrets: nil,
            skills: service, mcp: nil, skillScope: scope
        )

        _ = await tool.execute(ToolCall(id: "1", name: "skill_read", arguments: #"{"name":"reader"}"#))
        _ = await tool.execute(ToolCall(id: "2", name: "skill_read", arguments: #"{"name":"free"}"#))

        let active = await scope.activeSkill
        XCTAssertNil(active)
        let allowed = await scope.allows("bash")
        XCTAssertTrue(allowed)
    }

    func testGroupedSkillsKeepDescriptionsAndTriggersSurfaceMatches() async throws {
        for index in 0..<5 {
            _ = try skill("blender-\(index)", summary: "анимация \(index)", triggers: index == 2 ? ["анимация"] : [])
        }
        let service = service()

        let plain = await service.promptIndex(characterLimit: 8_000, query: nil)
        XCTAssertTrue(plain.contains("blender-* (5)"), plain)
        XCTAssertTrue(plain.contains("(анимация 2)"), "в группе должно быть короткое описание: \(plain)")

        let matched = await service.promptIndex(characterLimit: 8_000, query: "сделай анимацию сцены")
        XCTAssertTrue(matched.contains("★ blender-2"), matched)
    }

    func testSkillRemoveThenReadFails() async throws {
        _ = try skill("temporary")
        let service = service()
        let tool = ToolRegistry(
            workspace: root, memory: nil, embeddings: nil, secrets: nil,
            skills: service, mcp: nil
        )

        let removed = await tool.execute(ToolCall(id: "1", name: "skill_remove", arguments: #"{"name":"temporary"}"#))
        XCTAssertFalse(removed.isError, removed.output)

        let read = await tool.execute(ToolCall(id: "2", name: "skill_read", arguments: #"{"name":"temporary"}"#))
        XCTAssertTrue(read.isError)
    }

    func testInstallingAFolderWithASymlinkIsRefused() async throws {
        let source = try skill("linked")
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("link.md"),
            withDestinationURL: URL(fileURLWithPath: "/etc/hosts")
        )
        let importer = SkillImporter(userDirectory: root.appendingPathComponent("installed"))

        XCTAssertThrowsError(try importer.installDirectory(source, force: false))
    }
}
