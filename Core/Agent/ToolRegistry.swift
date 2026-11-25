import Foundation
import Vision
import AppKit

struct ToolResult: Sendable {
    let output: String
    let isError: Bool
    /// D3: the canonical value behind `output`, present only when the tool declared an
    /// output schema. `nil` on a tool that declares one is a developer error, not a
    /// silent pass-through.
    let canonicalValue: AnySendable?

    init(output: String, isError: Bool, canonicalValue: AnySendable? = nil) {
        self.output = output
        self.isError = isError
        self.canonicalValue = canonicalValue
    }

    static func ok(_ text: String) -> ToolResult { ToolResult(output: text, isError: false) }
    static func fail(_ text: String) -> ToolResult { ToolResult(output: text, isError: true) }

    /// A result whose value is checked against the tool's declared shape. `text` is the
    /// rendering the model reads; `value` is what a replay or a caller can rely on.
    static func canonical(_ value: [String: Any], text: String) -> ToolResult {
        ToolResult(output: text, isError: false, canonicalValue: AnySendable(value))
    }
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
    /// D3: declared shape of the result. When set, a successful result must come from
    /// `ToolResult.canonical` and pass `ToolOutputContract`.
    var outputSchema: [String: AnySendable]?
    /// D9: the tool may run concurrently with other safe tools in one batch. Default
    /// false, so a new tool is serialized until someone says otherwise.
    var isConcurrencySafe: Bool = false
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

    /// R32.2: tools the model already reached for this session. A tool used two steps
    /// ago is almost always still relevant, and this is the cheapest possible signal.
    private var used: [String] = []

    func recordUse(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        used.removeAll { $0 == name }
        used.append(name)
        if used.count > 12 { used.removeFirst(used.count - 12) }
    }

    func recentlyUsed() -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(used)
    }

    /// D11: one override layer over the built-in catalog. A name in `disabled` is not
    /// offered to the model at all; a name in `replaced` is offered with that definition
    /// instead. Nothing here touches the source of truth, so the rest of the catalog is
    /// untouched by construction.
    private var disabled: Set<String> = []
    private var replaced: [String: ToolDefinition] = [:]

    func disable(_ names: [String]) {
        lock.lock(); defer { lock.unlock() }
        disabled.formUnion(names)
    }

    func replace(_ definition: ToolDefinition) {
        lock.lock(); defer { lock.unlock() }
        replaced[definition.name] = definition
        disabled.remove(definition.name)
    }

    func clearOverrides() {
        lock.lock(); defer { lock.unlock() }
        disabled.removeAll()
        replaced.removeAll()
    }

    /// The catalog as the model will see it.
    func applyOverrides(_ base: [ToolDefinition]) -> [ToolDefinition] {
        lock.lock(); defer { lock.unlock() }
        return base.compactMap { definition in
            if disabled.contains(definition.name) { return nil }
            return replaced[definition.name] ?? definition
        }
    }
}

/// Stateless dispatcher: every dependency is an injected actor or a value.
///
/// Declared as a struct, not an actor, so independent read-only calls can actually
/// run in parallel — an actor serializes even `await`ed method calls.
struct ToolRegistry: Sendable {
    /// Shared root, not a snapshot: `workspace set` must reach every tool in the same
    /// turn, and a struct registry cannot mutate itself between calls (R20.4).
    let workspaceState: WorkspaceState
    var workspace: URL { workspaceState.url }
    /// R30.2: the user's message for this turn — the only text memory may cite.
    var currentUserMessage: String?
    var currentUserMessageID: Int64?
    /// R30.4: a subagent may read learned skills and report them, never write.
    var isSubagent: Bool = false
    /// R30.5: the operations ledger, present in the app and absent in pure tests.
    var operations: OperationLedger?
    /// R30.6: the action journal behind the `activity` tool.
    var actions: ActionJournal?
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
    let subagent: (@Sendable (String, Bool, SubagentDelivery, String) async -> SubagentOutcome)?
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
    /// I34: the same call returning the same result twice is a dead end; the third is
    /// refused before it runs. Shared by value copies of this registry.
    let repeatGuard: ToolRepeatGuard
    /// R32.3: the stop token, shared with the turn. Long tools subscribe to it.
    let cancel: AgentAbortSignal
    /// R32.3: per-turn count of memory lookups, logged once at the end of the turn.
    let memoryUsage: MemoryUsageCounter?
    /// D8: children of this registry. Nil for a registry that cannot spawn.
    let subagents: SubagentRegistry?
    /// Name of the agent owning this registry: `lead` or `agent-N`.
    let callerID: String

    init(
        workspace: URL,
        workspaceState: WorkspaceState? = nil,
        currentUserMessage: String? = nil,
        currentUserMessageID: Int64? = nil,
        isSubagent: Bool = false,
        operations: OperationLedger? = nil,
        actions: ActionJournal? = nil,
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
        subagent: (@Sendable (String, Bool, SubagentDelivery, String) async -> SubagentOutcome)? = nil,
        ledger: FileReadingLedger? = nil,
        skillScope: ActiveSkillScope? = nil,
        interceptors: ToolInterceptorChain = ToolInterceptorChain(),
        catalog: ToolCatalogState = ToolCatalogState(),
        processes: BackgroundProcessService? = nil,
        repeatGuard: ToolRepeatGuard = ToolRepeatGuard(),
        cancel: AgentAbortSignal = .shared,
        memoryUsage: MemoryUsageCounter? = nil,
        subagents: SubagentRegistry? = nil,
        callerID: String = SubagentRegistry.root
    ) {
        self.workspaceState = workspaceState ?? WorkspaceState(workspace)
        self.currentUserMessage = currentUserMessage
        self.currentUserMessageID = currentUserMessageID
        self.isSubagent = isSubagent
        self.operations = operations
        self.actions = actions
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
        self.repeatGuard = repeatGuard
        self.cancel = cancel
        self.memoryUsage = memoryUsage
        self.subagents = subagents
        self.callerID = callerID
    }

    static let mutatingTools: Set<String> = [
        "fs_write", "edit_file", "apply_patch", "trash_paths", "restore_trashed", "restore_version",
        "doc_write",
        "git_commit", "git_stash",
        "bash", "schedule_add", "schedule_remove", "memory_add", "memory_forget", "secret_save",
        "skill_install", "skill_remove", "index_workspace", "todowrite", "process", "app_script",
        "fs_copy", "fs_move", "fs_mkdir", "keyboard", "clipboard", "ui", "mouse",
        "git", "apps", "files"
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
        for definition in catalog.applyOverrides(Self.definitions) {
            if readOnly, await isMutating(definition.name) { continue }
            if let skillScope, !(await skillScope.allows(definition.name)) { continue }
            allowed.append(definition)
        }
        // R32.2: deferred tools are chosen for this turn instead of all being hidden
        // behind one line. The ranking sees the user's message, so "поставь будильник"
        // brings `schedule_add` in full; everything else stays a name and one line, and
        // tools that do not fit the budget are left out entirely.
        let selection = ToolSelector.select(
            definitions: allowed,
            query: currentUserMessage ?? "",
            recent: catalog.recentlyUsed(),
            loaded: Set(catalog.loadedNames())
        )

        var result: [ProviderToolSchema] = []
        for definition in allowed {
            if definition.exposure == .deferred, !catalog.isLoaded(definition.name) {
                if selection.expanded.contains(definition.name) {
                    result.append(ProviderToolSchema(
                        name: definition.name,
                        description: definition.description,
                        parameters: definition.parameters
                    ))
                } else if selection.compact.contains(definition.name) {
                    // One line is enough to know the tool exists and ask for its schema.
                    result.append(ProviderToolSchema(
                        name: definition.name,
                        description: Self.compactDescription(definition),
                        parameters: ["type": AnySendable("object"), "properties": AnySendable([String: Any]())]
                    ))
                }
                continue
            }
            result.append(ProviderToolSchema(
                name: definition.name,
                description: definition.description,
                parameters: definition.parameters
            ))
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
        switch (args["action"] as? String)?.lowercased() ?? "text" {
        case "permissions":
            return .ok(GrantInventory.text())
        case "tcc_panels":
            guard let service = args["service"] as? String else {
                return .fail("service обязателен: " + TCCPanels.services.keys.sorted().joined(separator: ", "))
            }
            guard TCCPanels.open(service) else {
                return .fail("Панель «\(service)» не открылась: неизвестный сервис или URL. "
                    + "Известные: " + TCCPanels.services.keys.sorted().joined(separator: ", "))
            }
            return .ok("Панель \(service) открыта. Галочку ставит человек: TCC кодом не пишется.")
        default:
            let sections = Set((args["sections"] as? [String] ?? []).map { $0.lowercased() })
            let path = (args["path"] as? String).map(resolve)
            return .ok(SystemReport.text(sections: sections, diskPath: path))
        }
    }

    static func compactDescription(_ definition: ToolDefinition) -> String {
        let first = definition.description
            .split(separator: ".", maxSplits: 1, omittingEmptySubsequences: true)
            .first.map(String.init) ?? definition.description
        let short = first.count > 96 ? String(first.prefix(96)) + "…" : first
        // The name is already in the list above; the marker only has to say how to get
        // the full schema. Spelling the tool name out here cost ~120 tokens across the
        // catalog, which is the difference between fitting the budget and not.
        return short + " [deferred: tool_load]"
    }

    func execute(_ call: ToolCall) async -> ToolResult {
        let context = ToolCallContext(workspace: workspace, readOnly: readOnly, cancel: cancel)
        // R32.3: the token is checked before every call, not only GUI ones. A stop must
        // not be followed by "well, the next tool still ran".
        if let reason = cancel.current {
            return .fail("аварийный стоп: \(reason). Ход остановлен, действие не выполнено.")
        }
        switch await interceptors.before(call, context: context) {
        case .denied(let result):
            return result
        case .allowed(let allowed):
            if repeatGuard.shouldRefuse(name: allowed.name, arguments: allowed.arguments) {
                return .fail(ToolRepeatGuard.refusal)
            }
            var result = await executeAllowed(allowed)
            // R35.4: a missing binary is a machine fact, not a tool bug. Answer with the
            // same sentence a person saw at launch instead of `command not found`.
            if result.isError,
               let human = EnvironmentCheck.toolError(
                    tool: allowed.name, output: result.output, state: EnvironmentCheck.state()
               ) {
                result = .fail(human)
            } else if result.isError,
                      let hint = GrantHint.line(for: result.output) {
                // R32.1: a grant refusal names the panel. Nothing is granted here; the
                // line only tells the person where the checkbox is.
                result = .fail(result.output + "\n\n" + hint)
            }
            if let problem = Self.outputProblem(tool: allowed.name, result: result) {
                ChatStore.logLatency("tool_output_contract name=\(allowed.name) \(problem)")
                result = .fail("Инструмент \(allowed.name) вернул значение, не проходящее "
                    + "объявленную схему: \(problem). Это ошибка реализации инструмента, "
                    + "а не аргументов.")
            }
            repeatGuard.record(name: allowed.name, arguments: allowed.arguments, output: result.output)
            catalog.recordUse(allowed.name)
            return await interceptors.after(allowed, result: result, context: context)
        }
    }

    /// D3: `process` and `network` keep their human text; the canonical value is the
    /// stable envelope a caller can read without parsing prose.
    static func canonicalEnvelope(_ result: ToolResult, action: String) -> ToolResult {
        guard !result.isError else { return result }
        return .canonical(
            ["action": action, "ok": true, "output": result.output],
            text: result.output
        )
    }

    /// `nil` when the tool declares no schema or the result is an error (errors are
    /// free-form by design: they explain what went wrong).
    static func outputProblem(tool: String, result: ToolResult) -> String? {
        guard !result.isError,
              let definition = ToolRegistry.definitions.first(where: { $0.name == tool }),
              let schema = definition.outputSchema else { return nil }
        guard let value = result.canonicalValue else {
            return "каноническое значение отсутствует"
        }
        return ToolOutputContract.problem(value: value.value, schema: schema)
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
            case "screenshot": return try await screenshot(args)
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
            case "memory_stats": return try await memoryStats(args)
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
            case "files": return await filesTool(args)
            case "apps": return appsTool(args)
            case "notify": return await notifyTool(args)
            case "ui": return uiTool(args)
            case "mouse": return mouseTool(args)
            case "clipboard": return clipboardTool(args)
            case "keyboard": return keyboardTool(args)
            case "process":
                return Self.canonicalEnvelope(
                    await processTool(args), action: args["action"] as? String ?? ""
                )
            case "network":
                return Self.canonicalEnvelope(
                    await networkTool(args), action: args["action"] as? String ?? ""
                )
            case "watch": return watchTool(args)
            case "spotlight": return await spotlightTool(args)
            case "workspace": return workspaceTool(args)
            case "power": return await powerTool(args)
            case "display": return await displayTool(args)
            case "launchd": return await launchdTool(args)
            case "settings": return await settingsTool(args)
            case "calendar": return await calendarTool(args)
            case "contacts": return await contactsTool(args)
            case "share": return await shareTool(args)
            case "observe": return await observeTool(args)
            case "skill_learn": return await skillLearnTool(args)
            case "activity": return await activityTool(args)
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
