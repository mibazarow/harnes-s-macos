import XCTest
@testable import Harness

final class AgentSafetyTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testSnapshotAndRestore() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try AppDatabase()
        let safety = FileSafetyService(
            database: database,
            versionsDirectory: root.appendingPathComponent("versions", isDirectory: true),
            trashDirectory: root.appendingPathComponent("trash", isDirectory: true)
        )

        let file = root.appendingPathComponent("note.txt")
        try "версия 1".write(to: file, atomically: true, encoding: .utf8)

        let stored = try await safety.snapshot(file)
        XCTAssertNotNil(stored)
        try "версия 2".write(to: file, atomically: true, encoding: .utf8)

        let versions = try await safety.versions(for: file.path)
        XCTAssertEqual(versions.count, 1)

        try await safety.restoreVersion(versions[0], to: file.path)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "версия 1")
    }

    func testTrashAndRestore() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try AppDatabase()
        let safety = FileSafetyService(
            database: database,
            versionsDirectory: root.appendingPathComponent("versions", isDirectory: true),
            trashDirectory: root.appendingPathComponent("trash", isDirectory: true)
        )

        let file = root.appendingPathComponent("deleteme.txt")
        try "данные".write(to: file, atomically: true, encoding: .utf8)

        let entry = try await safety.trash(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let list = try await safety.listTrash()
        XCTAssertEqual(list.count, 1)

        _ = try await safety.restore(entry.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "данные")
    }

    func testReadOnlyModeBlocksMutation() async {
        let registry = ToolRegistry(
            workspace: FileManager.default.temporaryDirectory,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil,
            readOnly: true
        )

        let schemas = await registry.schemas()
        XCTAssertFalse(schemas.contains { $0.name == "fs_write" })
        XCTAssertFalse(schemas.contains { $0.name == "bash" })
        XCTAssertTrue(schemas.contains { $0.name == "fs_read" })

        let result = await registry.execute(ToolCall(
            id: "1",
            name: "bash",
            arguments: #"{"command":"echo hi"}"#
        ))
        XCTAssertTrue(result.isError)
    }

    func testTodoStore() throws {
        let database = try AppDatabase()
        let todos = TodoStore(database: database)
        todos.set([
            ["text": "Прочитать файл", "status": "done"],
            ["text": "Починить баг", "status": "active"]
        ])

        XCTAssertEqual(todos.items.count, 2)
        XCTAssertTrue(todos.summary.contains("[x] Прочитать файл"))
        XCTAssertTrue(todos.summary.contains("[~] Починить баг"))
    }

    // MARK: - Write guard

    private func registry(workspace: URL, readOnly: Bool = false) -> ToolRegistry {
        ToolRegistry(
            workspace: workspace,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil,
            readOnly: readOnly
        )
    }

    func testWriteGuardRefusesSystemPaths() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = registry(workspace: root)

        for path in ["/etc/hosts", "/System/Library/x", "/usr/local/bin/x", "/bin/zsh"] {
            let result = await tools.execute(ToolCall(
                id: "1",
                name: "fs_write",
                arguments: "{\"path\":\"\(path)\",\"content\":\"x\"}"
            ))
            XCTAssertTrue(result.isError, "должна быть запрещена запись в \(path)")
        }
    }

    func testWriteGuardRefusesAppData() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = registry(workspace: root)

        let target = AppPaths.databaseURL.path
        let result = await tools.execute(ToolCall(
            id: "1",
            name: "fs_write",
            arguments: "{\"path\":\"\(target)\",\"content\":\"x\"}"
        ))
        XCTAssertTrue(result.isError, "агент не должен переписывать собственную базу")
    }

    func testWriteGuardAllowsWorkspaceAndUserPaths() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = registry(workspace: root)

        let inside = await tools.execute(ToolCall(
            id: "1",
            name: "fs_write",
            arguments: #"{"path":"note.txt","content":"привет"}"#
        ))
        XCTAssertFalse(inside.isError)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("note.txt"), encoding: .utf8), "привет")

        let outside = root.appendingPathComponent("..").appendingPathComponent("harness-outside-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: outside) }
        let result = await tools.execute(ToolCall(
            id: "2",
            name: "fs_write",
            arguments: "{\"path\":\"\(outside.path)\",\"content\":\"ok\"}"
        ))
        XCTAssertFalse(result.isError, "обычные пользовательские пути должны быть доступны")
    }

    func testTrashRefusesSystemPath() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let database = try AppDatabase()
        let safety = FileSafetyService(
            database: database,
            versionsDirectory: root.appendingPathComponent("versions", isDirectory: true),
            trashDirectory: root.appendingPathComponent("trash", isDirectory: true)
        )
        let tools = ToolRegistry(
            workspace: root,
            memory: nil,
            embeddings: nil,
            secrets: nil,
            skills: nil,
            mcp: nil,
            fileSafety: safety
        )

        let result = await tools.execute(ToolCall(
            id: "1",
            name: "trash_paths",
            arguments: #"{"paths":["/etc/hosts"]}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(FileManager.default.fileExists(atPath: "/etc/hosts"))
    }

    // MARK: - Arguments and secrets

    func testMalformedJsonIsReportedAsJson() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = registry(workspace: root)

        let result = await tools.execute(ToolCall(
            id: "1",
            name: "fs_read",
            arguments: #"{"path" "note.txt"}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("JSON"), "ошибка должна называть настоящую причину: \(result.output)")
    }

    func testSecretSearchNeverReturnsValues() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try AppDatabase()
        let secrets = SecretsService(database: database)
        _ = try await secrets.save(alias: "deploy", value: "super-secret-token", note: "сервер")

        let tools = ToolRegistry(
            workspace: root,
            memory: nil,
            embeddings: nil,
            secrets: secrets,
            skills: nil,
            mcp: nil
        )

        let search = await tools.execute(ToolCall(
            id: "1",
            name: "secret_search",
            arguments: #"{"query":"deploy"}"#
        ))
        XCTAssertFalse(search.isError)
        XCTAssertFalse(search.output.contains("super-secret-token"), "поиск не должен раскрывать значение")

        let list = await tools.execute(ToolCall(id: "2", name: "secret_search", arguments: #"{"query":""}"#))
        XCTAssertFalse(list.output.contains("super-secret-token"))
    }

    // MARK: - Shell

    func testShellTimeoutIsReported() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = registry(workspace: root)

        let result = await tools.execute(ToolCall(
            id: "1",
            name: "bash",
            arguments: #"{"command":"sleep 5","timeout_ms":1000}"#
        ))
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.lowercased().contains("таймаут"))
    }

    func testShellHandlesLargeOutput() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = registry(workspace: root)

        // More than a pipe buffer: the old implementation deadlocked here. The tool
        // caps what it returns, but it must return, and return quickly.
        let result = await tools.execute(ToolCall(
            id: "1",
            name: "bash",
            arguments: #"{"command":"yes | head -c 200000","timeout_ms":20000}"#
        ))
        XCTAssertFalse(result.isError, result.output)
        XCTAssertGreaterThan(result.output.count, 10_000)
    }

    func testGrepReturnsContextLines() async throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        line one
        line two
        needle here
        line four
        line five
        """.write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)

        let tools = registry(workspace: root)
        let result = await tools.execute(ToolCall(
            id: "1",
            name: "fs_grep",
            arguments: #"{"pattern":"needle","before":1,"after":1}"#
        ))
        XCTAssertFalse(result.isError)
        XCTAssertTrue(result.output.contains("line two"))
        XCTAssertTrue(result.output.contains("line four"))
    }
}
