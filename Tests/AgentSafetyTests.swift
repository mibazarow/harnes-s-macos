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
}
