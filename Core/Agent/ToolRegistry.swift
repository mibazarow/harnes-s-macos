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
    private let workspace: URL
    private let memory: MemoryService?
    private let embeddings: EmbeddingsService?
    private let secrets: SecretsService?
    private let skills: SkillsService?
    private let mcp: MCPService?
    private let mcpManager: MCPManager?
    private let indexer: WorkspaceIndexer?
    private let scheduler: SchedulerService?
    private let fileSafety: FileSafetyService?
    private let todos: TodoStore?
    private let readOnly: Bool
    private let subagent: (@Sendable (String, Bool) async -> String)?

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
            return .fail("Некорректные аргументы инструмента \(call.name): \(call.arguments)")
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
            case "search_code": return await searchCode(args)
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

    private static func decodeArguments(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8), !raw.isEmpty else { return [:] }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static let dataSubdirectories: Set<String> = [
        "artifacts", "tools", "config", "workspace", "models",
        "versions", "trash", "logs", "backups", "database"
    ]

    private func resolve(_ path: String) -> URL {
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

    private func display(_ url: URL) -> String {
        let home = NSHomeDirectory()
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

// MARK: - Files
    private func listFiles(_ args: [String: Any]) throws -> ToolResult {
        let url = resolve(args["path"] as? String ?? ".")
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        var lines = ["\(display(url)) — \(entries.count) записей"]
        for entry in entries.prefix(400) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let size = (try? entry.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            lines.append(isDir ? "  \(entry.lastPathComponent)/" : "  \(entry.lastPathComponent)  \(size) B")
        }
        return .ok(lines.joined(separator: "\n"))
    }

    private func readFile(_ args: [String: Any]) throws -> ToolResult {
        guard let path = args["path"] as? String else { return .fail("path обязателен") }
        let url = resolve(path)
        let offset = max((args["offset"] as? Int) ?? 1, 1)
        let limit = min(max((args["limit"] as? Int) ?? 400, 1), 2_000)
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n")
        let slice = lines.dropFirst(offset - 1).prefix(limit)
        var out = slice.enumerated().map { "\(offset + $0.offset): \($0.element)" }.joined(separator: "\n")
        if lines.count > offset - 1 + limit {
            out += "\n… (всего \(lines.count) строк)"
        }
        return .ok(out.isEmpty ? "(пусто)" : out)
    }

    private func writeFile(_ args: [String: Any]) async throws -> ToolResult {
        guard let path = args["path"] as? String, let content = args["content"] as? String else {
            return .fail("path и content обязательны")
        }
        let url = resolve(path)
        try AppPaths.ensureDirectory(url.deletingLastPathComponent())
        _ = try? await fileSafety?.snapshot(url)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return .ok("Записано: \(display(url)) (\(content.count) симв.)")
    }

    private func editFile(_ args: [String: Any]) async throws -> ToolResult {
        guard let path = args["path"] as? String,
              let old = args["old_text"] as? String,
              let new = args["new_text"] as? String else {
            return .fail("path, old_text и new_text обязательны")
        }
        let url = resolve(path)
        var content = try String(contentsOf: url, encoding: .utf8)
        guard content.contains(old) else {
            return .fail("Фрагмент не найден в \(display(url))")
        }
        _ = try? await fileSafety?.snapshot(url)
        content = content.replacingOccurrences(of: old, with: new, options: .literal, range: content.range(of: old))
        try content.write(to: url, atomically: true, encoding: .utf8)
        return .ok("Изменено: \(display(url))")
    }

    private func grep(_ args: [String: Any]) throws -> ToolResult {
        guard let pattern = args["pattern"] as? String else { return .fail("pattern обязателен") }
        var command = "rg --line-number --no-heading --color never -e \(Self.shellQuote(pattern))"
        if let glob = args["glob"] as? String, !glob.isEmpty {
            command += " -g \(Self.shellQuote(glob))"
        }
        command += " " + Self.shellQuote(display(resolve(args["path"] as? String ?? ".")))
        let result = try Self.runSync(command, cwd: workspace, timeout: 30)
        return .ok(result.isEmpty ? "Совпадений нет." : String(result.prefix(20_000)))
    }

    private func glob(_ args: [String: Any]) throws -> ToolResult {
        guard let pattern = args["pattern"] as? String else { return .fail("pattern обязателен") }
        let command = "find . -type f -name \(Self.shellQuote(pattern)) -not -path '*/.git/*' | head -200"
        let result = try Self.runSync(command, cwd: workspace, timeout: 30)
        return .ok(result.isEmpty ? "Файлов не найдено." : result)
    }

// MARK: - Shell and process
    private func runShell(_ args: [String: Any]) async throws -> ToolResult {
        guard let command = args["command"] as? String else { return .fail("command обязателен") }
        let timeout = TimeInterval(min(max((args["timeout_ms"] as? Int) ?? 60_000, 1_000), 600_000)) / 1_000
        let output = try await Task.detached(priority: .userInitiated) {
            try Self.runSync(command, cwd: self.workspace, timeout: timeout)
        }.value
        return .ok(output.isEmpty ? "(команда выполнена, вывода нет)" : String(output.prefix(30_000)))
    }

    static func runSync(_ command: String, cwd: URL, timeout: TimeInterval) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = cwd

        // Output goes to files, not pipes: a command that prints more than the pipe
        // buffer holds would block on write, never exit, and die on the timeout with
        // its output lost.
        let directory = FileManager.default.temporaryDirectory
        let outURL = directory.appendingPathComponent("harness-out-\(UUID().uuidString)")
        let errURL = directory.appendingPathComponent("harness-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }

        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        process.standardOutput = outHandle
        process.standardError = errHandle

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            throw NSError(domain: "Harness", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Команда превысила таймаут \(Int(timeout)) с и была остановлена."
            ])
        }

        try? outHandle.close()
        try? errHandle.close()

        let out = String(data: (try? Data(contentsOf: outURL)) ?? Data(), encoding: .utf8) ?? ""
        let err = String(data: (try? Data(contentsOf: errURL)) ?? Data(), encoding: .utf8) ?? ""
        let merged = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
        return "exit \(process.terminationStatus)\n" + merged
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

// MARK: - Web and vision
    private func fetchURL(_ args: [String: Any]) async throws -> ToolResult {
        guard let raw = args["url"] as? String, let url = URL(string: raw) else {
            return .fail("url обязателен")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) Harness/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return .fail("HTTP \(http.statusCode) для \(raw)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            return .fail("Ответ не является текстом")
        }
        return .ok(Self.plainText(fromHTML: html, limit: 30_000))
    }

    private func webSearch(_ args: [String: Any]) async throws -> ToolResult {
        guard let query = args["query"] as? String, !query.isEmpty else { return .fail("query обязателен") }
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            return .fail("Не удалось построить запрос")
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return .fail("Некорректный запрос") }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) Harness/1.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(data: data, encoding: .utf8) ?? ""

        let pattern = #"<a[^>]*class="result__a"[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let range = NSRange(html.startIndex..., in: html)
        var results: [String] = []
        for match in regex.matches(in: html, range: range).prefix(10) {
            guard let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html) else { continue }
            let link = String(html[urlRange])
            let title = Self.plainText(fromHTML: String(html[titleRange]), limit: 200)
            results.append("- \(title)\n  \(link)")
        }
        return .ok(results.isEmpty ? "Ничего не найдено." : results.joined(separator: "\n"))
    }

    private func browser(_ args: [String: Any]) async throws -> ToolResult {
        guard let action = args["action"] as? String else { return .fail("action обязателен") }

        let tools = AppPaths.dataDirectory.appendingPathComponent("tools", isDirectory: true)
        try AppPaths.ensureDirectory(tools)
        try AppPaths.ensureDirectory(AppPaths.artifactsDirectory)

        let scriptURL = tools.appendingPathComponent("browser.mjs")
        try Self.playwrightScript.write(to: scriptURL, atomically: true, encoding: .utf8)

        if !FileManager.default.fileExists(atPath: tools.appendingPathComponent("node_modules/playwright").path) {
            return .fail("Playwright не установлен. Один раз выполни: cd ~/HARNES_S_DATA/tools && npm i playwright@1.63.0 && npx playwright install chromium")
        }

        var payload: [String: Any] = ["action": action]
        for key in ["url", "selector", "value", "path"] {
            if let value = args[key] as? String { payload[key] = value }
        }
        if let raw = payload["path"] as? String {
            payload["path"] = resolve(raw).path
        }
        if payload["path"] == nil, action == "screenshot" {
            payload["path"] = AppPaths.artifactsDirectory
                .appendingPathComponent("page-\(Int(Date().timeIntervalSince1970)).png").path
        }
        let json = String(data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8) ?? "{}"

        let command = "node \(Self.shellQuote(scriptURL.path)) \(Self.shellQuote(json))"
        let output = try await Task.detached(priority: .userInitiated) {
            try Self.runSync(command, cwd: tools, timeout: 180)
        }.value
        return .ok(String(output.prefix(40_000)))
    }

    private static let playwrightScript = """
    import { chromium } from 'playwright';
    import { resolve } from 'node:path';

    const args = JSON.parse(process.argv[2] || '{}');
    if (args.action !== 'goto' && !args.url) {
      console.error('Нужен параметр url: без него открывается пустая страница about:blank.');
      process.exit(2);
    }
    const browser = await chromium.launch({ headless: true });
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
    try {
      if (args.url) {
        await page.goto(args.url, { waitUntil: 'load', timeout: 45000 });
        await page.waitForTimeout(500);
      }
      switch (args.action) {
        case 'goto':
          console.log('title:', await page.title());
          console.log('url:', page.url());
          break;
        case 'text':
          console.log((await page.innerText('body')).slice(0, 20000));
          break;
        case 'html':
          console.log((await page.content()).slice(0, 20000));
          break;
        case 'click':
          await page.click(args.selector, { timeout: 20000 });
          console.log('clicked', args.selector);
          break;
        case 'fill':
          await page.fill(args.selector, args.value || '', { timeout: 20000 });
          console.log('filled', args.selector);
          break;
        case 'screenshot': {
          const path = args.path || 'shot.png';
          await page.screenshot({ path, fullPage: true });
          console.log('Скриншот: ' + resolve(path));
          break;
        }
        case 'open':
          console.log('title:', await page.title());
          console.log('url:', page.url());
          console.log((await page.innerText('body')).slice(0, 20000));
          break;
        default:
          console.log('unknown action');
      }
    } finally {
      await browser.close();
    }
    """

    private func screenshot(_ args: [String: Any]) throws -> ToolResult {
        try AppPaths.ensureDirectory(AppPaths.artifactsDirectory)
        let name = "screen-\(Int(Date().timeIntervalSince1970)).png"
        let path = AppPaths.artifactsDirectory.appendingPathComponent(name)
        var command = "screencapture -x"
        if let windowID = args["window_id"] as? Int {
            command += " -o -l \(windowID)"
        }
        command += " \(Self.shellQuote(path.path))"
        _ = try Self.runSync(command, cwd: workspace, timeout: 30)
        return .ok("Скриншот: \(path.path)\nПоказать пользователю: путь можно передать в ocr(path: \"\(path.path)\").")
    }

    private func ocr(_ args: [String: Any]) throws -> ToolResult {
        guard let raw = args["path"] as? String else { return .fail("path обязателен") }
        let url = resolve(raw)
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return .fail("Не удалось открыть изображение: \(display(url))")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: cgImage).perform([request])

        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return .ok(lines.isEmpty ? "Текст не распознан." : lines.joined(separator: "\n"))
    }

// MARK: - Code editing
    private func applyPatch(_ args: [String: Any]) async throws -> ToolResult {
        guard let path = args["path"] as? String, let patch = args["patch"] as? String else {
            return .fail("Нужны path и patch")
        }

        let url = resolve(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .fail("Файл не найден: \(display(url))")
        }

        let original = try String(contentsOf: url, encoding: .utf8)
        let updated: String
        do {
            updated = try PatchApplier.apply(patch, to: original)
        } catch {
            return .fail("Патч не применён: \(error.localizedDescription)")
        }

        _ = try? await fileSafety?.snapshot(url)
        try updated.write(to: url, atomically: true, encoding: .utf8)

        let before = original.components(separatedBy: "\n").count
        let after = updated.components(separatedBy: "\n").count
        return .ok("Патч применён: \(display(url)) (\(before) → \(after) строк)")
    }

    private func readMany(_ args: [String: Any]) throws -> ToolResult {
        guard let paths = args["paths"] as? [String], !paths.isEmpty else {
            return .fail("paths обязателен")
        }
        let limit = max(1, min((args["limit"] as? Int) ?? 200, 1_000))

        var blocks: [String] = []
        for path in paths.prefix(20) {
            let url = resolve(path)
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                blocks.append("=== \(path) — не читается")
                continue
            }
            let lines = content.components(separatedBy: "\n")
            let shown = lines.prefix(limit)
            var block = "=== \(display(url)) (\(lines.count) строк)\n"
            block += shown.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "\n")
            if lines.count > limit {
                block += "\n… ещё \(lines.count - limit) строк"
            }
            blocks.append(block)
        }
        return .ok(blocks.joined(separator: "\n\n"))
    }

    private func projectOverview(_ args: [String: Any]) -> ToolResult {
        let root = (args["path"] as? String).map(resolve) ?? workspace
        let inspector = ProjectInspector(workspace: root)
        return .ok(inspector.render(inspector.inspect()))
    }

    private func searchCode(_ args: [String: Any]) async -> ToolResult {
        guard let memory else { return .fail("Память недоступна") }
        guard let query = args["query"] as? String, !query.isEmpty else {
            return .fail("query обязателен")
        }
        let limit = max(1, min((args["limit"] as? Int) ?? 8, 30))

        if let embeddings {
            let hits = await HybridSearch(memory: memory, embeddings: embeddings).search(query, limit: limit)
            let codeHits = hits.filter { $0.item.kind == "code" }
            guard !codeHits.isEmpty else {
                return .ok("В индексе нет совпадений. Сначала вызови index_workspace.")
            }
            return .ok(codeHits.map { hit in
                "#\(hit.item.id) \(hit.item.snippet)"
            }.joined(separator: "\n"))
        }

        let hits = (try? await memory.search(query, limit: limit)) ?? []
        guard !hits.isEmpty else { return .ok("Ничего не найдено.") }
        return .ok(hits.map { "#\($0.id) \($0.snippet)" }.joined(separator: "\n"))
    }

    private func gitCommit(_ args: [String: Any]) throws -> ToolResult {
        guard let message = args["message"] as? String, !message.isEmpty else {
            return .fail("message обязателен")
        }
        let paths = (args["paths"] as? [String]) ?? []

        var outputs: [String] = []
        if paths.isEmpty {
            outputs.append(try Self.runSync("git add -A", cwd: workspace, timeout: 60))
        } else {
            let quoted = paths.map { Self.shellQuote(resolve($0).path) }.joined(separator: " ")
            outputs.append(try Self.runSync("git add \(quoted)", cwd: workspace, timeout: 60))
        }

        outputs.append(try Self.runSync("git commit -m \(Self.shellQuote(message))", cwd: workspace, timeout: 120))
        outputs.append(try Self.runSync("git log --oneline -1", cwd: workspace, timeout: 30))
        return .ok(outputs.joined(separator: "\n"))
    }

    private func gitStash(_ args: [String: Any]) throws -> ToolResult {
        guard let action = args["action"] as? String else { return .fail("action обязателен") }
        let command: String
        switch action {
        case "push": command = "git stash push -u"
        case "pop": command = "git stash pop"
        case "list": command = "git stash list"
        default: return .fail("action: push | pop | list")
        }
        return .ok(try Self.runSync(command, cwd: workspace, timeout: 60))
    }

    private func tree(_ args: [String: Any]) throws -> ToolResult {
        let root = resolve(args["path"] as? String ?? ".")
        // 4 по умолчанию: local/components/vendor.name/templates/.default/ — как раз
        // типовая глубина битриксового компонента, иначе шаблоны не видно.
        let depth = max(1, min((args["depth"] as? Int) ?? 4, 8))
        return .ok(Self.renderTree(root: root, depth: depth, display: display))
    }

    /// Shared with tests. Hidden files and hidden directories are included on
    /// purpose: `.description.php`, `templates/.default`, `.env.example` are part
    /// of real projects, especially Bitrix.
    static func renderTree(
        root: URL,
        depth: Int,
        display: (URL) -> String
    ) -> String {
        let skip: Set<String> = [
            ".git", "node_modules", ".build", "build", "dist", "vendor",
            ".venv", "venv", "Pods", "DerivedData", ".next", "target", "__pycache__"
        ]

        var lines: [String] = [display(root) + "/"]

        func walk(_ url: URL, prefix: String, level: Int) {
            guard level <= depth else { return }
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { return }

            let sorted = entries.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }

            for entry in sorted.prefix(200) {
                let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isDir, skip.contains(entry.lastPathComponent) { continue }
                lines.append(prefix + entry.lastPathComponent + (isDir ? "/" : ""))
                if isDir {
                    walk(entry, prefix: prefix + "  ", level: level + 1)
                }
            }
        }

        walk(root, prefix: "  ", level: 1)
        return lines.joined(separator: "\n")
    }

// MARK: - Reversible deletion
    private func trashPaths(_ args: [String: Any]) async throws -> ToolResult {
        guard let fileSafety else { return .fail("Корзина недоступна") }
        guard let raw = args["paths"] as? [String], !raw.isEmpty else {
            return .fail("paths обязателен")
        }

        var moved: [String] = []
        for path in raw {
            let url = resolve(path)
            guard url.path != workspace.path else {
                return .fail("Нельзя удалить саму рабочую папку.")
            }
            do {
                let entry = try await fileSafety.trash(url)
                moved.append("#\(entry.id) \(entry.originalPath)")
            } catch {
                return .fail("\(path): \(error.localizedDescription)")
            }
        }
        return .ok("В корзину:\n" + moved.joined(separator: "\n"))
    }

    private func undoList() async throws -> ToolResult {
        guard let fileSafety else { return .fail("Корзина недоступна") }
        let entries = try await fileSafety.listTrash()
        guard !entries.isEmpty else { return .ok("Корзина пуста.") }
        return .ok(entries.map { "#\($0.id) \($0.originalPath) — \($0.createdAt)" }.joined(separator: "\n"))
    }

    private func restoreTrashed(_ args: [String: Any]) async throws -> ToolResult {
        guard let fileSafety else { return .fail("Корзина недоступна") }
        guard let id = (args["id"] as? Int).map(Int64.init) ?? (args["id"] as? Double).map({ Int64($0) }) else {
            return .fail("Нужен id")
        }
        let path = try await fileSafety.restore(id)
        return .ok("Восстановлено: \(path)")
    }

    private func fileVersions(_ args: [String: Any]) async throws -> ToolResult {
        guard let fileSafety else { return .fail("Версии недоступны") }
        guard let path = args["path"] as? String else { return .fail("path обязателен") }
        let versions = try await fileSafety.versions(for: resolve(path).path)
        guard !versions.isEmpty else { return .ok("Версий нет.") }
        return .ok(versions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
    }

    private func restoreVersion(_ args: [String: Any]) async throws -> ToolResult {
        guard let fileSafety else { return .fail("Версии недоступны") }
        guard let path = args["path"] as? String, let version = args["version"] as? String else {
            return .fail("Нужны path и version")
        }
        let target = resolve(path)
        try await fileSafety.restoreVersion(version, to: target.path)
        return .ok("Восстановлено из версии: \(display(target))")
    }

// MARK: - Agent state
    private func runSubagent(_ args: [String: Any]) async -> ToolResult {
        guard let subagent else { return .fail("Подагенты недоступны") }
        guard let prompt = args["prompt"] as? String, !prompt.isEmpty else {
            return .fail("prompt обязателен")
        }
        let readOnly = (args["read_only"] as? Bool) ?? true
        let answer = await subagent(prompt, readOnly)
        return .ok(answer.isEmpty ? "(подагент ничего не вернул)" : String(answer.prefix(20_000)))
    }

    private func todoWrite(_ args: [String: Any]) -> ToolResult {
        guard let todos else { return .fail("План недоступен") }

        let payload: Any = args["items"] ?? args["todos"] ?? args["tasks"] ?? args
        todos.set(json: payload)

        guard !todos.items.isEmpty else {
            return .fail("План не принят: у элементов нет поля text. Пример: \"items\": [{\"text\": \"шаг\", \"status\": \"pending\"}]")
        }
        return .ok("План обновлён:\n" + todos.summary)
    }

    private func todoRead() -> ToolResult {
        guard let todos else { return .fail("План недоступен") }
        return .ok(todos.summary)
    }

    private func git(_ args: [String]) throws -> ToolResult {
        let command = "git " + args.joined(separator: " ")
        let output = try Self.runSync(command, cwd: workspace, timeout: 30)
        return .ok(output)
    }

    private func gitDiff(_ args: [String: Any]) throws -> ToolResult {
        let staged = (args["staged"] as? Bool) ?? false
        return try git(staged ? ["diff", "--staged", "--stat", "-p"] : ["diff", "--stat", "-p"])
    }

    private func gitLog(_ args: [String: Any]) throws -> ToolResult {
        let limit = max(1, min((args["limit"] as? Int) ?? 10, 100))
        return try git(["log", "--oneline", "-n", "\(limit)"])
    }

// MARK: - Scheduler
    private func scheduleAdd(_ args: [String: Any]) throws -> ToolResult {
        guard let scheduler else { return .fail("Планировщик недоступен") }
        guard let title = args["title"] as? String,
              let prompt = args["prompt"] as? String,
              let minutes = (args["interval_minutes"] as? Int) ?? (args["interval_minutes"] as? Double).map(Int.init) else {
            return .fail("Нужны title, prompt и interval_minutes")
        }

        let task = try scheduler.add(title: title, prompt: prompt, intervalMinutes: minutes)
        return .ok("Расписание #\(task.id) создано: «\(task.title)» каждые \(task.intervalMinutes) мин.")
    }

    private func scheduleList() throws -> ToolResult {
        guard let scheduler else { return .fail("Планировщик недоступен") }
        let tasks = try scheduler.list()
        guard !tasks.isEmpty else { return .ok("Расписаний нет.") }

        return .ok(tasks.map { task in
            let state = task.enabled ? "вкл" : "выкл"
            return "#\(task.id) «\(task.title)» — каждые \(task.intervalMinutes) мин, \(state), следующее: \(task.nextRunAt)"
        }.joined(separator: "\n"))
    }

    private func scheduleRemove(_ args: [String: Any]) throws -> ToolResult {
        guard let scheduler else { return .fail("Планировщик недоступен") }
        guard let id = (args["id"] as? Int).map(Int64.init) ?? (args["id"] as? Double).map({ Int64($0) }) else {
            return .fail("Нужен id")
        }
        try scheduler.remove(id: id)
        return .ok("Расписание #\(id) удалено.")
    }

// MARK: - Memory and indexing
    private func indexWorkspace(_ args: [String: Any]) async -> ToolResult {
        guard let indexer else { return .fail("Индексатор недоступен") }
        let root = args["path"].flatMap { $0 as? String }.map(resolve) ?? workspace
        let progress = await indexer.index(root: root)

        var lines = [
            "Проиндексировано: \(progress.filesIndexed) файлов, \(progress.chunksIndexed) фрагментов",
            "Пропущено: \(progress.skipped)"
        ]
        if let error = progress.error {
            lines.append("Замечание: \(error)")
        }
        return .ok(lines.joined(separator: "\n"))
    }

    private func memoryAdd(_ args: [String: Any]) async throws -> ToolResult {
        guard let memory else { return .fail("Память недоступна") }
        guard let text = args["text"] as? String else { return .fail("text обязателен") }
        let pinned = (args["pinned"] as? Bool) ?? false
        let item = try await memory.add(
            text,
            kind: (args["kind"] as? String) ?? "fact",
            pinned: pinned
        )

        if let embeddings {
            let hash = MemoryService.hash(item.content)
            if let existing = try? await embeddings.vector(refKind: "memory", textHash: hash) {
                try? await embeddings.store(refKind: "memory", refID: String(item.id), vector: existing, textHash: hash)
            } else if let vector = try? await embeddings.embed([item.content]).first {
                try? await embeddings.store(refKind: "memory", refID: String(item.id), vector: vector, textHash: hash)
            }
        }

        let mark = item.pinned ? " (закреплено)" : ""
        return .ok("Запомнил #\(item.id)\(mark): \(item.content)")
    }

    private func memoryForget(_ args: [String: Any]) async throws -> ToolResult {
        guard let memory else { return .fail("Память недоступна") }
        guard let query = args["query"] as? String, !query.isEmpty else {
            return .fail("query обязателен: id записи или текст")
        }
        // The user asked to forget this, so a pinned record goes too.
        let removed = try await memory.forget(query: query, force: true)
        guard !removed.isEmpty else { return .ok("Ничего не найдено — забывать нечего.") }
        return .ok("Забыто:\n" + removed.map { "#\($0.id) \($0.content)" }.joined(separator: "\n"))
    }

    private func memoryList(_ args: [String: Any]) async throws -> ToolResult {
        guard let memory else { return .fail("Память недоступна") }
        let items = try await memory.list(limit: 60)
        guard !items.isEmpty else { return .ok("Память пуста.") }
        return .ok(items.map { item in
            let mark = item.pinned ? "📌 " : ""
            return "#\(item.id) \(mark)[\(item.kind)] \(item.content)"
        }.joined(separator: "\n"))
    }

    private func memorySearch(_ args: [String: Any]) async throws -> ToolResult {
        guard let memory else { return .fail("Память недоступна") }
        guard let query = args["query"] as? String else { return .fail("query обязателен") }

        if let embeddings {
            let hits = await HybridSearch(memory: memory, embeddings: embeddings).search(query)
            guard !hits.isEmpty else { return .ok("Ничего не найдено.") }
            return .ok(hits.prefix(8).map { hit in
                let source = hit.semanticScore != nil ? "semantic+fts" : "fts"
                return "#\(hit.item.id) [\(hit.item.kind)] (\(source)) \(hit.item.content)"
            }.joined(separator: "\n"))
        }

        let hits = try await memory.search(query)
        guard !hits.isEmpty else { return .ok("Ничего не найдено.") }
        return .ok(hits.prefix(8).map { "#\($0.id) [\($0.kind)] \($0.content)" }.joined(separator: "\n"))
    }

// MARK: - Secrets
    private func secretSave(_ args: [String: Any]) async throws -> ToolResult {
        guard let secrets else { return .fail("Секреты недоступны") }
        guard let alias = args["alias"] as? String, let value = args["value"] as? String else {
            return .fail("alias и value обязательны")
        }
        let item = try await secrets.save(alias: alias, value: value, note: args["note"] as? String)
        return .ok("Секрет сохранён: \(item.alias)")
    }

    private func secretGet(_ args: [String: Any]) async throws -> ToolResult {
        guard let secrets else { return .fail("Секреты недоступны") }
        guard let alias = args["alias"] as? String else { return .fail("alias обязателен") }
        guard let item = try await secrets.get(alias: alias) else {
            return .fail("Секрет '\(alias)' не найден")
        }
        return .ok(item.value)
    }

    private func secretSearch(_ args: [String: Any]) async throws -> ToolResult {
        guard let secrets else { return .fail("Секреты недоступны") }
        guard let query = args["query"] as? String else { return .fail("query обязателен") }
        let items = try await secrets.search(query)
        guard !items.isEmpty else { return .ok("Ничего не найдено.") }
        return .ok(items.map { "\($0.alias) — \($0.note ?? "")" }.joined(separator: "\n"))
    }

// MARK: - Skills and MCP
    private func skillList() async -> ToolResult {
        guard let skills else { return .fail("Скиллы недоступны") }
        let records = await skills.list()
        guard !records.isEmpty else { return .ok("Скиллов нет.") }
        return .ok(records.map { "\($0.name) [\($0.scope.rawValue), \($0.enabled ? "вкл" : "выкл")] — \($0.summary)" }.joined(separator: "\n"))
    }

    private func skillRead(_ args: [String: Any]) async -> ToolResult {
        guard let skills else { return .fail("Скиллы недоступны") }
        guard let name = args["name"] as? String, !name.isEmpty else { return .fail("name обязателен") }
        do {
            return .ok(try await skills.read(name: name))
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func skillInstall(_ args: [String: Any]) async -> ToolResult {
        guard let skills else { return .fail("Скиллы недоступны") }
        guard let source = args["source"] as? String else { return .fail("source обязателен") }
        do {
            let record = try await skills.install(from: source, force: (args["force"] as? Bool) ?? false)
            return .ok("Скилл установлен: \(record.name)")
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func mcpTools(_ args: [String: Any]) async -> ToolResult {
        guard let mcpManager else { return .fail("MCP-клиент недоступен") }
        let server = args["server"] as? String
        let tool = args["tool"] as? String
        let all = await mcpManager.tools()
        let filtered = all.filter { server == nil || $0.server == server }
        guard !filtered.isEmpty else {
            return .ok(server.map { "У сервера \($0) нет инструментов." } ?? "Инструментов MCP нет.")
        }

        if let tool {
            guard let match = filtered.first(where: { $0.name == tool }) else {
                return .fail("Инструмент \(tool) не найден.")
            }
            return .ok(renderMCPTool(match))
        }

        if server != nil {
            return .ok(filtered.map { "- \($0.name): \(String($0.description.prefix(200)))" + $0.argsLabel }.joined(separator: "\n"))
        }

        var lines: [String] = []
        for (name, group) in Dictionary(grouping: filtered, by: \.server).sorted(by: { $0.key < $1.key }) {
            lines.append("## \(name)")
            lines.append(contentsOf: group.map { "- \($0.name): \(String($0.description.prefix(160)))" + $0.argsLabel })
        }
        return .ok(String(lines.joined(separator: "\n").prefix(20_000)))
    }

    private func renderMCPTool(_ tool: MCPToolDescriptor) -> String {
        var text = "# \(tool.server) / \(tool.name)\n\(tool.description)\n"
        text += "Exposure: \(tool.exposure)" + tool.argsLabel + "\n\n"
        let plain = tool.inputSchema.mapValues { $0.value }
        if let data = try? JSONSerialization.data(withJSONObject: plain, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            text += json
        }
        return String(text.prefix(20_000))
    }

    private func callMCP(_ call: ToolCall, args: [String: Any]) async -> ToolResult {
        guard let mcpManager else { return .fail("MCP-клиент недоступен") }
        let parts = call.name.split(separator: "__", maxSplits: 2)
        guard parts.count == 3 else { return .fail("Некорректное имя MCP-инструмента: \(call.name)") }

        let server = String(parts[1])
        let tool = String(parts[2])
        let json = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        do {
            let output = try await mcpManager.call(server: server, tool: tool, argumentsJSON: json)
            return .ok(output.isEmpty ? "(пустой ответ)" : String(output.prefix(30_000)))
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    private func mcpList() async -> ToolResult {
        guard let mcp else { return .fail("MCP недоступен") }
        do {
            let servers = try await mcp.list()
            guard !servers.isEmpty else { return .ok("MCP-серверов нет.") }
            let live = await mcpManager?.sessionsSnapshot() ?? []
            let byName = Dictionary(uniqueKeysWithValues: live.map { ($0.name, $0) })

            return .ok(servers.map { server in
                let state = byName[server.name]
                let status = state.map { "\($0.running ? "запущен" : "остановлен"), \($0.tools) инстр." } ?? "не запускался"
                return "\(server.name) [\(server.transport.rawValue), \(server.enabled ? "вкл" : "выкл"), \(status)] — \(server.summary)"
            }.joined(separator: "\n"))
        } catch {
            return .fail(error.localizedDescription)
        }
    }

// MARK: - Helpers
    static func plainText(fromHTML html: String, limit: Int) -> String {
        var text = html
        for pattern in [
            #"(?is)<script[\s\S]*?</script>"#,
            #"(?is)<style[\s\S]*?</style>"#,
            #"(?is)<head[\s\S]*?</head>"#,
            #"(?is)<!--[\s\S]*?-->"#
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</(p|div|li|h[1-6]|tr)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"&nbsp;"#, with: " ")
        text = text.replacingOccurrences(of: #"&amp;"#, with: "&")
        text = text.replacingOccurrences(of: #"&lt;"#, with: "<")
        text = text.replacingOccurrences(of: #"&gt;"#, with: ">")
        text = text.replacingOccurrences(of: #"&quot;"#, with: "\"")
        text = text.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "\n…" : trimmed
    }
}