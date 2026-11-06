import Foundation
import Vision
import AppKit

struct ToolResult: Sendable {
    let output: String
    let isError: Bool

    static func ok(_ text: String) -> ToolResult { ToolResult(output: text, isError: false) }
    static func fail(_ text: String) -> ToolResult { ToolResult(output: text, isError: true) }
}

struct ToolDefinition: Sendable {
    let name: String
    let description: String
    let parameters: [String: AnySendable]
}

actor ToolRegistry {
    let workspace: URL
    let memory: MemoryService?
    let embeddings: EmbeddingsService?
    let secrets: SecretsService?
    let skills: SkillsService?
    let mcp: MCPService?
    let mcpManager: MCPManager?
    let indexer: WorkspaceIndexer?
    let scheduler: SchedulerService?
    let fileSafety: FileSafetyService?
    let todos: TodoStore?
    let readOnly: Bool
    let subagent: (@Sendable (String, Bool) async -> String)?

    init(
        workspace: URL,
        memory: MemoryService?,
        embeddings: EmbeddingsService?,
        secrets: SecretsService?,
        skills: SkillsService?,
        mcp: MCPService?,
        mcpManager: MCPManager? = nil,
        indexer: WorkspaceIndexer? = nil,
        scheduler: SchedulerService? = nil,
        fileSafety: FileSafetyService? = nil,
        todos: TodoStore? = nil,
        readOnly: Bool = false,
        subagent: (@Sendable (String, Bool) async -> String)? = nil
    ) {
        self.workspace = workspace
        self.memory = memory
        self.embeddings = embeddings
        self.secrets = secrets
        self.skills = skills
        self.mcp = mcp
        self.mcpManager = mcpManager
        self.indexer = indexer
        self.scheduler = scheduler
        self.fileSafety = fileSafety
        self.todos = todos
        self.readOnly = readOnly
        self.subagent = subagent
    }

    static let mutatingTools: Set<String> = [
        "fs_write", "edit_file", "apply_patch", "trash_paths", "restore_trashed", "restore_version",
        "git_commit", "git_stash",
        "bash", "schedule_add", "schedule_remove", "memory_add", "memory_forget", "secret_save",
        "skill_install", "index_workspace", "todowrite", "mcp__"
    ]

    private func isMutating(_ name: String) -> Bool {
        if name.hasPrefix("mcp__") { return true }
        return Self.mutatingTools.contains(name)
    }

// MARK: - Catalog and dispatch
    func schemas() async -> [ProviderToolSchema] {
        var result = Self.definitions
            .filter { !readOnly || !isMutating($0.name) }
            .map {
            ProviderToolSchema(name: $0.name, description: $0.description, parameters: $0.parameters)
        }

        if let mcpManager, !readOnly {
            // The tool list must stay identical between turns: a tool appearing or
            // disappearing changes the cached prefix and costs a full re-prefill.
            let remote = await mcpManager.toolsForRequest()
            for tool in remote {
                if tool.exposure == "deferred" {
                    result.append(ProviderToolSchema(
                        name: tool.qualifiedName,
                        description: String("[MCP \(tool.server)] ".appending(tool.compactDescription).prefix(600)),
                        parameters: tool.compactParameters
                    ))
                } else {
                    result.append(ProviderToolSchema(
                        name: tool.qualifiedName,
                        description: "[MCP \(tool.server)] \(tool.description)",
                        parameters: tool.inputSchema
                    ))
                }
            }
        }

        return result
    }

    func execute(_ call: ToolCall) async -> ToolResult {
        if readOnly, isMutating(call.name) {
            return .fail("Инструмент \(call.name) недоступен: активен режим только-чтение.")
        }

        guard let args = Self.decodeArguments(call.arguments) else {
            // Name the real cause: the model produced invalid JSON, not a missing field.
            // The old generic wording sent it chasing a phantom parameter.
            let preview = call.arguments.count > 200
                ? String(call.arguments.prefix(200)) + "…"
                : call.arguments
            return .fail(
                "Аргументы \(call.name) — невалидный JSON: \(preview.isEmpty ? "(пусто)" : preview). "
                + "Вызови инструмент заново с корректным JSON-объектом."
            )
        }

        do {
            switch call.name {
            case "fs_list": return try listFiles(args)
            case "fs_read": return try readFile(args)
            case "fs_write": return try await writeFile(args)
            case "edit_file": return try await editFile(args)
            case "apply_patch": return try await applyPatch(args)
            case "read_many": return try readMany(args)
            case "project_overview": return projectOverview(args)
            case "search_code": return try await searchCode(args)
            case "git_commit": return try gitCommit(args)
            case "git_stash": return try gitStash(args)
            case "fs_tree": return try tree(args)
            case "trash_paths": return try await trashPaths(args)
            case "undo_list": return try await undoList()
            case "restore_trashed": return try await restoreTrashed(args)
            case "file_versions": return try await fileVersions(args)
            case "restore_version": return try await restoreVersion(args)
            case "task": return await runSubagent(args)
            case "todowrite": return todoWrite(args)
            case "todo_read": return todoRead()
            case "git_status": return try git(["status", "--short", "--branch"])
            case "git_diff": return try gitDiff(args)
            case "git_log": return try gitLog(args)
            case "fs_grep": return try grep(args)
            case "fs_glob": return try glob(args)
            case "bash": return try await runShell(args)
            case "webfetch": return try await fetchURL(args)
            case "websearch": return try await webSearch(args)
            case "browser": return try await browser(args)
            case "screenshot": return try screenshot(args)
            case "ocr": return try ocr(args)
            case "index_workspace": return await indexWorkspace(args)
            case "schedule_add": return try scheduleAdd(args)
            case "schedule_list": return try scheduleList()
            case "schedule_remove": return try scheduleRemove(args)
            case "memory_add": return try await memoryAdd(args)
            case "memory_search": return try await memorySearch(args)
            case "memory_forget": return try await memoryForget(args)
            case "memory_list": return try await memoryList(args)
            case "secret_save": return try await secretSave(args)
            case "secret_get": return try await secretGet(args)
            case "secret_search": return try await secretSearch(args)
            case "skill_list": return await skillList()
            case "skill_read": return await skillRead(args)
            case "skill_install": return await skillInstall(args)
            case "mcp_list": return await mcpList()
            case "mcp_tools": return await mcpTools(args)
            default:
                if call.name.hasPrefix("mcp__") {
                    return await callMCP(call, args: args)
                }
                return .fail("Неизвестный инструмент: \(call.name)")
            }
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    static func decodeArguments(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8), !raw.isEmpty else { return [:] }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static let dataSubdirectories: Set<String> = [
        "artifacts", "tools", "config", "workspace", "models",
        "versions", "trash", "logs", "backups", "database"
    ]

    /// Paths that must never be written by the agent, even on an explicit request.
    /// Everything else outside the workspace is allowed: the user often asks to put a
    /// file in Documents or on the Desktop, and blocking that would be worse than useless.
    static let forbiddenWriteRoots: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/private/etc", "/private/var/db",
        "/Library", "/Applications", "/cores", "/dev"
    ]

    func writeGuard(_ url: URL) -> ToolResult? {
        let path = url.standardizedFileURL.path
        if path == "/" {
            return .fail("Запись в корень файловой системы запрещена.")
        }
        for root in Self.forbiddenWriteRoots where path == root || path.hasPrefix(root + "/") {
            return .fail("Запись в \(root) запрещена: это системный каталог.")
        }
        let protected = [
            AppPaths.databaseDirectory, AppPaths.configDirectory, AppPaths.logsDirectory,
            AppPaths.modelsDirectory, AppPaths.versionsDirectory, AppPaths.trashDirectory,
            AppPaths.backupsDirectory
        ]
        for directory in protected {
            let base = directory.standardizedFileURL.path
            if path == base || path.hasPrefix(base + "/") {
                return .fail("Запись в \(display(directory)) запрещена: это служебные данные приложения.")
            }
        }
        return nil
    }

    func resolve(_ path: String) -> URL {
        let expanded = (path as NSString).expandingTildeInPath

        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL
        }

        let firstComponent = expanded.split(separator: "/").first.map(String.init) ?? ""
        if Self.dataSubdirectories.contains(firstComponent) {
            return URL(fileURLWithPath: expanded, relativeTo: AppPaths.dataDirectory).standardizedFileURL
        }

        return URL(fileURLWithPath: expanded, relativeTo: workspace).standardizedFileURL
    }

    func display(_ url: URL) -> String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
