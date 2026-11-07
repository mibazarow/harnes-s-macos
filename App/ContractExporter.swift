#if DEBUG
import CryptoKit
import Foundation
import GRDB

/// Exports the cross-platform contract used by the Windows port: database shape,
/// tool catalog and the hash of the base system prompt.
///
///     Harness.app/Contents/MacOS/Harness --export-contracts /path/to/contract.json
///
/// Debug only. The Windows repository checks this file in and tests itself against it
/// (see WINDOWS_PORT.md §2.4).
enum ContractExporter {
    static func handleCommandLine() -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--export-contracts") else { return false }

        let path = arguments.count > flag + 1
            ? arguments[flag + 1]
            : FileManager.default.currentDirectoryPath + "/contract.json"

        do {
            let data = try build()
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            print("contract written to \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("contract export failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func build() throws -> Data {
        let database = try AppDatabase(inMemory: true)

        let tables = try database.queue.read { db -> [String: [String]] in
            let names = try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
            )
            var result: [String: [String]] = [:]
            for name in names {
                result[name] = try Row.fetchAll(db, sql: "PRAGMA table_info(\(name))")
                    .compactMap { $0["name"] as String? }
            }
            return result
        }

        let tools: [[String: Any]] = ToolRegistry.definitions.map { definition in
            [
                "name": definition.name,
                "description": definition.description,
                "parameters": definition.parameters.mapValues(\.value)
            ]
        }

        let promptHash = SHA256.hash(data: Data(Prompts.system.utf8))
            .map { String(format: "%02x", $0) }
            .joined()

        let contract: [String: Any] = [
            "contractVersion": 1,
            "databaseSchemaVersion": 8,
            "dataDirectoryName": "HARNES_S_DATA",
            "promptSHA256": promptHash,
            "tables": tables,
            "tools": tools
        ]

        return try JSONSerialization.data(
            withJSONObject: contract,
            options: [.prettyPrinted, .sortedKeys]
        )
    }
}
#endif