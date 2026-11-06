import Foundation

enum AppPaths {
    static var dataDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("HARNES_S_DATA", isDirectory: true)
    }

    static var databaseDirectory: URL {
        dataDirectory.appendingPathComponent("database", isDirectory: true)
    }

    static var databaseURL: URL {
        databaseDirectory.appendingPathComponent("harness.db")
    }

    static var configDirectory: URL {
        dataDirectory.appendingPathComponent("config", isDirectory: true)
    }

    static var userSkillsDirectory: URL {
        configDirectory.appendingPathComponent("skills", isDirectory: true)
    }

    static var mcpConfigURL: URL {
        configDirectory.appendingPathComponent("mcp.json")
    }

    static var modelsDirectory: URL {
        dataDirectory.appendingPathComponent("models", isDirectory: true)
    }

    /// Where the EmbeddingGemma 2 files live. Downloaded after install, not shipped
    /// inside the app bundle, so the data folder stays the one movable unit.
    static var embeddingModelDirectory: URL {
        modelsDirectory.appendingPathComponent("embeddinggemma-2", isDirectory: true)
    }

    static var workspaceDirectory: URL {
        dataDirectory.appendingPathComponent("workspace", isDirectory: true)
    }

    static var artifactsDirectory: URL {
        dataDirectory.appendingPathComponent("artifacts", isDirectory: true)
    }

    static var versionsDirectory: URL {
        dataDirectory.appendingPathComponent("versions", isDirectory: true)
    }

    static var trashDirectory: URL {
        dataDirectory.appendingPathComponent("trash", isDirectory: true)
    }

    static var logsDirectory: URL {
        dataDirectory.appendingPathComponent("logs", isDirectory: true)
    }

    static var backupsDirectory: URL {
        dataDirectory.appendingPathComponent("backups", isDirectory: true)
    }

    static func bootstrap() throws {
        for directory in [
            dataDirectory,
            databaseDirectory,
            configDirectory,
            userSkillsDirectory,
            modelsDirectory,
            workspaceDirectory,
            artifactsDirectory,
            versionsDirectory,
            trashDirectory,
            logsDirectory,
            backupsDirectory
        ] {
            try ensureDirectory(directory)
        }
    }

    static func ensureDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}