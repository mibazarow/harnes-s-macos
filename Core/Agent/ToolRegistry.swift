import Foundation
import Vision
import AppKit

struct ToolResult: Sendable {
    let output: String
    let isError: Bool

    static func ok(_ text: String) -> ToolResult { ToolResult(output: text, isError: false) }
    static func fail(_ text: String) -> ToolResult { ToolResult(output: text, isError: true) }
}

/// How a definition travels in the catalog. `deferred` tools keep their name and one
/// line in every request; the full schema is fetched by `tool_load` when needed. The
/// catalog is a permanent tax on context, so the rare groups pay only when used.
enum ToolExposure: String, Sendable {
    case core
    case normal
    case deferred
}

struct ToolDefinition: Sendable {
    let name: String
    var exposure: ToolExposure = .normal
    let description: String
    let parameters: [String: AnySendable]
}

/// Session-scoped set of schemas the model asked to see in full.
final class ToolCatalogState: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded: Set<String> = []

    func isLoaded(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return loaded.contains(name)
    }

    func load(_ names: [String]) {
        lock.lock(); defer { lock.unlock() }
        loaded.formUnion(names)
    }

    func loadedNames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return loaded.sorted()
    }
}

/// Stateless dispatcher: every dependency is an injected actor or a value.
///
/// Declared as a struct, not an actor, so independent read-only calls can actually
/// run in parallel — an actor serializes even `await`ed method calls.
struct ToolRegistry: Sendable {
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
    let processes: BackgroundProcessService?
    let readOnly: Bool
    let subagent: (@Sendable (String, Bool) async -> SubagentOutcome)?
    /// Session-scoped read state. Shared across turns so "read it first" survives the
    /// step boundary; a subagent gets its own because it has its own context.
    let ledger: FileReadingLedger
    /// Restriction declared by the last skill that was read.
    let skillScope: ActiveSkillScope?
    /// Gates in front of every call. Empty by default: a registry without interceptors
    /// behaves exactly as before.
    let interceptors: ToolInterceptorChain
    /// Shared across turns so `tool_load` stays in effect until the session ends.
    let catalog: ToolCatalogState

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
        subagent: (@Sendable (String, Bool) async -> SubagentOutcome)? = nil,
        ledger: FileReadingLedger? = nil,
        skillScope: ActiveSkillScope? = nil,
        interceptors: ToolInterceptorChain = ToolInterceptorChain(),
        catalog: ToolCatalogState = ToolCatalogState(),
        processes: BackgroundProcessService? = nil
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
        self.processes = processes
        self.readOnly = readOnly
        self.subagent = subagent
        self.ledger = ledger ?? FileReadingLedger()
        self.skillScope = skillScope
        self.interceptors = interceptors
        self.catalog = catalog
    }

    static let mutatingTools: Set<String> = [
        "fs_write", "edit_file", "apply_patch", "trash_paths", "restore_trashed", "restore_version",
        "doc_write",
        "git_commit", "git_stash",
        "bash", "schedule_add", "schedule_remove", "memory_add", "memory_forget", "secret_save",
        "skill_install", "skill_remove", "index_workspace", "todowrite", "process", "app_script",
        "fs_copy", "fs_move", "fs_mkdir", "keyboard", "clipboard", "ui", "mouse",
        "git"
    ]

    /// Refuses a blind write.
    ///
    /// The reference agents require a read before rewriting a file, and require a fresh
    /// read when the file changed on disk since. Without this an `edit_file` by marker
    /// is a guess: the agent has no idea what it is replacing.
    func requireFreshRead(_ url: URL) async -> ToolResult? {
        switch await ledger.status(of: url) {
        case .fresh:
            return nil
        case .neverRead:
            return .fail("Сначала прочитай файл: \(display(url)). Правка вслепую запрещена — "
                + "вызови fs_read (или read_many), потом повтори.")
        case .changed:
            return .fail("Файл изменился после чтения: \(display(url)). "
                + "Перечитай его через fs_read и повтори правку.")
        }
    }

    /// Unknown MCP servers count as mutating: the base list cannot describe them, and
    /// guessing "read" would let an unknown tool write in plan mode. A server whose
    /// config says `isReadOnly` keeps its tools available.
    private func isMutating(_ name: String) async -> Bool {
        if name.hasPrefix("mcp__") {
            guard let mcpManager else { return true }
            return !(await mcpManager.isReadOnly(toolNamed: name))
        }
        return Self.mutatingTools.contains(name)
    }

// MARK: - Catalog and dispatch
    func schemas() async -> [ProviderToolSchema] {
        var allowed: [ToolDefinition] = []
        for definition in Self.definitions {
            if readOnly, await isMutating(definition.name) { continue }
            if let skillScope, !(await skillScope.allows(definition.name)) { continue }
            allowed.append(definition)
        }
        var result = allowed.map { definition -> ProviderToolSchema in
            if definition.exposure == .deferred, !catalog.isLoaded(definition.name) {
                // One line is enough to know the tool exists and ask for its schema.
                return ProviderToolSchema(
                    name: definition.name,
                    description: Self.compactDescription(definition),
                    parameters: ["type": AnySendable("object"), "properties": AnySendable([String: Any]())]
                )
            }
            return ProviderToolSchema(
                name: definition.name,
                description: definition.description,
                parameters: definition.parameters
            )
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

    func systemTool(_ args: [String: Any]) -> ToolResult {
        let sections = Set((args["sections"] as? [String] ?? []).map { $0.lowercased() })
        return .ok(SystemReport.text(sections: sections))
    }

    static func compactDescription(_ definition: ToolDefinition) -> String {
        let first = definition.description
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? definition.description
        let short = first.count > 110 ? String(first.prefix(110)) + "…" : first
        return short + " [schema: tool_load(\"\(definition.name)\")]"
    }

    func execute(_ call: ToolCall) async -> ToolResult {
        let context = ToolCallContext(workspace: workspace, readOnly: readOnly)
        switch await interceptors.before(call, context: context) {
        case .denied(let result):
            return result
        case .allowed(let allowed):
            let result = await executeAllowed(allowed)
            return await interceptors.after(allowed, result: result, context: context)
        }
    }

    private func executeAllowed(_ call: ToolCall) async -> ToolResult {
        if let denial = await skillScope?.denialReason(call.name) {
            return .fail(denial)
        }
        if readOnly, await isMutating(call.name) {
            return .fail("Инструмент \(call.name) недоступен: активен режим только-чтение.")
        }

        guard let args = Self.decodeArguments(call.arguments) else {
            // Name the real cause: the model produced invalid JSON, not a missing field.
            // The old generic wording sent it chasing a phantom parameter.
            let preview = call.arguments.count > 200
                ? String(call.arguments.prefix(200)) + "…"
                : call.arguments
            if let hint = deferredSchemaHint(call.name) {
                return .fail("Аргументы \(call.name) — невалидный JSON: "
                    + "\(preview.isEmpty ? "(пусто)" : preview).\n" + hint)
            }
            return .fail(
                "Аргументы \(call.name) — невалидный JSON: \(preview.isEmpty ? "(пусто)" : preview). "
                + "Вызови инструмент заново с корректным JSON-объектом."
            )
        }

        do {
            switch call.name {
            case "fs_list": return try listFiles(args)
            case "fs_copy": return try fileOperation("copy", args)
            case "fs_move": return try fileOperation("move", args)
            case "fs_mkdir": return try fileOperation("mkdir", args)
            case "fs_read": return try await readFile(args)
            case "fs_write": return try await writeFile(args)
            case "edit_file": return try await editFile(args)
            case "apply_patch": return try await applyPatch(args)
            case "read_many": return try await readMany(args)
            case "project_overview": return projectOverview(args)
            case "search_code": return try await searchCode(args)
            case "git_commit": return try await gitCommit(args)
            case "git_stash": return try await gitStash(args)
            case "fs_tree": return try tree(args)
            case "trash_paths": return try await trashPaths(args)
            case "undo_list": return try await undoList()
            case "restore_trashed": return try await restoreTrashed(args)
            case "file_versions": return try await fileVersions(args)
            case "restore_version": return try await restoreVersion(args)
            case "task": return await runSubagent(args)
            case "todowrite": return todoWrite(args)
            case "todo_read": return todoRead()
            case "git": return await gitTool(args)
            case "git_status": return try await git(["status", "--short", "--branch"])
            case "git_diff": return try await gitDiff(args)
            case "git_log": return try await gitLog(args)
            case "fs_grep": return try await grep(args)
            case "fs_glob": return try await glob(args)
            case "bash": return try await runShell(args)
            case "webfetch": return try await fetchURL(args)
            case "websearch": return try await webSearch(args)
            case "browser": return try await browser(args)
            case "screenshot": return try screenshot(args)
            case "ocr": return try ocr(args)
            case "app_logs": return try await appLogs(args)
            case "doc_read": return try await docRead(args)
            case "doc_write": return try await docWrite(args)
            case "image_read": return try await imageRead(args)
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
            case "skill_remove": return await skillRemove(args)
            case "mcp_list": return await mcpList()
            case "mcp_tools": return await mcpTools(args)
            case "tool_load": return toolLoad(args)
            case "system": return systemTool(args)
            case "permissions": return permissionsTool()
            case "notify": return await notifyTool(args)
            case "ui": return uiTool(args)
            case "mouse": return mouseTool(args)
            case "clipboard": return clipboardTool(args)
            case "keyboard": return keyboardTool(args)
            case "process": return await processTool(args)
            case "network": return await networkTool(args)
            case "watch": return watchTool(args)
            case "spotlight": return await spotlightTool(args)
            case "windows": return windowsTool(args)
            case "shortcut": return await shortcutTool(args)
            case "app_script": return await appScriptTool(args)
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
        // Both spellings reach us from models and shell snippets. `expandingTildeInPath`
        // only knows "~", so "$HOME" was passed through literally.
        let home = NSHomeDirectory()
        let expanded = (path as NSString).expandingTildeInPath
            .replacingOccurrences(of: "${HOME}", with: home)
            .replacingOccurrences(of: "$HOME", with: home)

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
