import XCTest
@testable import Harness

final class SelfConfigTests: XCTestCase {
    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeSkill(to directory: URL, name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = """
        ---
        name: \(name)
        description: Demo skill for tests
        version: 1.0.0
        triggers:
          - demo
        allowed-tools:
          - fs_read
        ---
        # Body

        Do the thing.
        """
        try text.write(
            to: directory.appendingPathComponent("SKILL.md"),
            atomically: true,
            encoding: .utf8
        )
    }

    func testManifestParsing() throws {
        let text = """
        ---
        name: demo
        description: Demo skill
        version: 1.2.3
        triggers:
          - one
          - two
        allowed-tools: [fs_read, bash]
        ---
        # Body
        """
        let manifest = try SkillManifest.parse(text, fallbackName: "fallback")
        XCTAssertEqual(manifest.name, "demo")
        XCTAssertEqual(manifest.summary, "Demo skill")
        XCTAssertEqual(manifest.version, "1.2.3")
        XCTAssertEqual(manifest.triggers, ["one", "two"])
        XCTAssertEqual(manifest.allowedTools, ["fs_read", "bash"])
        XCTAssertEqual(manifest.body, "# Body")
    }

    func testSkillManifestParsesFoldedDescription() throws {
        let text = """
        ---
        name: folded
        description: >
          First line of the summary
          and the second line.
        version: 2.0.0
        ---
        # Body
        """
        let manifest = try SkillManifest.parse(text, fallbackName: "fallback")
        XCTAssertEqual(manifest.summary, "First line of the summary and the second line.")
    }

    func testSkillInstallDisableRemove() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("source", isDirectory: true)
        try writeSkill(to: source, name: "demo-skill")

        let service = SkillsService(
            userDirectory: root.appendingPathComponent("user", isDirectory: true),
            builtinDirectory: nil
        )

        let record = try await service.install(from: source.path)
        XCTAssertEqual(record.name, "demo-skill")
        XCTAssertEqual(record.scope, .user)

        let initial = await service.list()
        XCTAssertEqual(initial.count, 1)
        XCTAssertTrue(initial[0].enabled)

        try await service.setEnabled(name: "demo-skill", enabled: false)
        let disabled = await service.list()
        XCTAssertFalse(disabled[0].enabled)

        do {
            _ = try await service.install(from: source.path)
            XCTFail("Повторная установка без --force должна падать")
        } catch {
            XCTAssertTrue(error is ConfigurationError)
        }

        try await service.remove(name: "demo-skill")
        let empty = await service.list()
        XCTAssertTrue(empty.isEmpty)
    }

    func testBuiltinSkillIsReadOnly() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let builtin = root.appendingPathComponent("builtin", isDirectory: true)
        try writeSkill(to: builtin.appendingPathComponent("builtin-skill", isDirectory: true), name: "builtin-skill")

        let service = SkillsService(
            userDirectory: root.appendingPathComponent("user", isDirectory: true),
            builtinDirectory: builtin
        )

        let records = await service.list()
        XCTAssertEqual(records.first?.scope, .builtin)

        do {
            try await service.remove(name: "builtin-skill")
            XCTFail("Встроенный скилл нельзя удалить")
        } catch let error as ConfigurationError {
            guard case .builtinReadOnly = error else {
                return XCTFail("Ожидалась builtinReadOnly, получено \(error)")
            }
        }
    }

    func testSkillReadReturnsBodyAndFiles() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let builtin = root.appendingPathComponent("builtin", isDirectory: true)
        let skillDir = builtin.appendingPathComponent("demo-read", isDirectory: true)
        try writeSkill(to: skillDir, name: "demo-read")
        try FileManager.default.createDirectory(
            at: skillDir.appendingPathComponent("scripts"),
            withIntermediateDirectories: true
        )
        try "print('hi')".write(
            to: skillDir.appendingPathComponent("scripts/run.py"),
            atomically: true,
            encoding: .utf8
        )

        let service = SkillsService(
            userDirectory: root.appendingPathComponent("user", isDirectory: true),
            builtinDirectory: builtin
        )

        let text = try await service.read(name: "demo-read")
        let records = await service.list()
        let record = try XCTUnwrap(records.first)
        XCTAssertTrue(text.contains("# Skill: demo-read"))
        XCTAssertTrue(text.contains("Path: \(record.directory.path)"))
        XCTAssertTrue(text.contains("scripts/run.py"))
        XCTAssertTrue(text.contains("Do the thing."))

        do {
            _ = try await service.read(name: "missing")
            XCTFail("Неизвестный скилл должен падать")
        } catch {
            XCTAssertTrue(error is ConfigurationError)
        }
    }

    func testPromptIndexSkipsDisabledSkills() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let builtin = root.appendingPathComponent("builtin", isDirectory: true)
        try writeSkill(to: builtin.appendingPathComponent("alpha", isDirectory: true), name: "alpha")
        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeSkill(to: user.appendingPathComponent("beta", isDirectory: true), name: "beta")

        let service = SkillsService(userDirectory: user, builtinDirectory: builtin)
        try await service.setEnabled(name: "beta", enabled: false)

        let index = await service.promptIndex()
        XCTAssertTrue(index.contains("- alpha: Demo skill for tests"))
        XCTAssertFalse(index.contains("beta"))
    }

    func testBundledSkillsAreLoadable() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let service = SkillsService(userDirectory: root.appendingPathComponent("user", isDirectory: true))
        let records = await service.list()
        let builtin = records.filter { $0.scope == .builtin }
        XCTAssertGreaterThanOrEqual(builtin.count, 5, "В бандл должны попасть базовые скиллы")

        let index = await service.promptIndex()
        XCTAssertFalse(index.isEmpty)
        XCTAssertLessThanOrEqual(index.count, 8000)
        XCTAssertTrue(index.contains("- coding:"))

        let body = try await service.read(name: "coding")
        XCTAssertTrue(body.contains("Path: "))
        XCTAssertTrue(body.contains("Scope: builtin"))
    }

    func testPromptIndexGroupsLargePrefixes() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let user = root.appendingPathComponent("user", isDirectory: true)
        for suffix in ["a", "b", "c", "d", "e"] {
            try writeSkill(to: user.appendingPathComponent("grp-\(suffix)", isDirectory: true), name: "grp-\(suffix)")
        }
        let service = SkillsService(
            userDirectory: user,
            builtinDirectory: root.appendingPathComponent("builtin", isDirectory: true)
        )

        let index = await service.promptIndex()
        XCTAssertTrue(index.contains("- grp-* (5): a, b, c, d, e"))
        XCTAssertFalse(index.contains("- grp-a:"))
    }

    func testSkillIndexIsCachedUntilChange() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let user = root.appendingPathComponent("user", isDirectory: true)
        try writeSkill(to: user.appendingPathComponent("cached", isDirectory: true), name: "cached")
        let service = SkillsService(
            userDirectory: user,
            builtinDirectory: root.appendingPathComponent("builtin", isDirectory: true)
        )

        let first = await service.promptIndex()
        XCTAssertTrue(first.contains("- cached:"))

        // Added behind the cache's back: the cached index must not change.
        try writeSkill(to: user.appendingPathComponent("late", isDirectory: true), name: "late")
        let second = await service.promptIndex()
        XCTAssertEqual(first, second)

        // An explicit change through the service invalidates it.
        try await service.setEnabled(name: "cached", enabled: false)
        let third = await service.promptIndex()
        XCTAssertFalse(third.contains("- cached:"))
    }

    func testMCPAddDisableRemove() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let service = MCPService(configURL: root.appendingPathComponent("config/mcp.json"))
        let server = MCPServerConfig(
            name: "demo",
            transport: .stdio,
            command: "npx",
            args: ["-y", "@demo/server"]
        )

        try await service.add(server)
        let initial = try await service.list()
        XCTAssertEqual(initial.count, 1)
        XCTAssertEqual(initial[0].summary, "npx -y @demo/server")

        do {
            try await service.add(server)
            XCTFail("Дубликат без --force должен падать")
        } catch {
            XCTAssertTrue(error is ConfigurationError)
        }

        try await service.setEnabled(name: "demo", enabled: false)
        let disabled = try await service.list()
        XCTAssertFalse(disabled[0].enabled)

        try await service.remove(name: "demo")
        let empty = try await service.list()
        XCTAssertTrue(empty.isEmpty)
    }
}