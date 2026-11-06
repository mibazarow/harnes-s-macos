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