import Foundation

struct MCPToolDescriptor: Sendable {
    let server: String
    let name: String
    let description: String
    let inputSchema: [String: AnySendable]
    var exposure: String = "full"

    var qualifiedName: String { "mcp__\(server)__\(name)" }

    var argumentNames: [String] {
        guard let properties = inputSchema["properties"]?.value as? [String: Any] else { return [] }
        return properties.keys.sorted()
    }

    var requiredArguments: Set<String> {
        guard let required = inputSchema["required"]?.value as? [String] else { return [] }
        return Set(required)
    }

    /// A permissive schema for deferred servers: tool names stay callable, nested detail is loaded on demand.
    var compactParameters: [String: AnySendable] {
        ["type": AnySendable("object"), "additionalProperties": AnySendable(true)]
    }

    var argsLabel: String {
        let names = argumentNames
        guard !names.isEmpty else { return "" }
        let required = requiredArguments
        let rendered = names.map { required.contains($0) ? "\($0)*" : $0 }
        return " Args (* = required): " + rendered.joined(separator: ", ")
    }

    var compactDescription: String { description + argsLabel }
}

enum MCPError: LocalizedError {
    case serverNotFound(String)
    case startFailed(String)
    case notInitialized(String)
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .serverNotFound(let name):
            "MCP-сервер «\(name)» не найден в конфиге."
        case .startFailed(let reason):
            "Не удалось запустить MCP-сервер: \(reason)"
        case .notInitialized(let name):
            "MCP-сервер «\(name)» не инициализировался."
        case .rpc(let message):
            "Ошибка MCP: \(message)"
        }
    }
}

/// One stdio MCP connection: spawn → initialize → tools/list → tools/call.
actor MCPSession {
    private let config: MCPServerConfig
    private var process: Process?
    private var stdin: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<String, Error>] = [:]
    private var buffer = Data()
    private var initialized = false
    private var stdoutTask: Task<Void, Never>?
    private var cachedTools: [MCPToolDescriptor] = []
    private let logURL: URL

    init(config: MCPServerConfig) {
        self.config = config
        self.logURL = AppPaths.logsDirectory.appendingPathComponent("mcp-\(config.name).log")
    }

    var tools: [MCPToolDescriptor] { cachedTools }
    var isRunning: Bool { process?.isRunning == true }

    func ensureStarted() async throws {
        if process?.isRunning == true, initialized { return }
        try start()
        try await initialize()
        cachedTools = try await listTools()
    }

    private func start() throws {
        guard config.transport == .stdio, let command = config.command else {
            throw MCPError.startFailed("поддерживается только stdio, HTTP/SSE пока нет")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + (config.args ?? [])

        var environment = ProcessInfo.processInfo.environment
        let extraPATH = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin").path
        ].joined(separator: ":")
        environment["PATH"] = (environment["PATH"] ?? "") + ":" + extraPATH
        for (key, value) in config.env ?? [:] {
            environment[key] = value
        }
        process.environment = environment

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        try? AppPaths.ensureDirectory(AppPaths.logsDirectory)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        logHandle?.seekToEndOfFile()

        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            logHandle?.write(data)
        }

        try process.run()

        self.process = process
        self.stdin = inPipe.fileHandleForWriting
        self.buffer = Data()

        let outHandle = outPipe.fileHandleForReading
        // The read loop must NOT run on the actor: `availableData` blocks, and
        // holding the actor while blocked prevents `handle` from resuming the
        // pending continuation (deadlock).
        stdoutTask = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                let data = outHandle.availableData
                if data.isEmpty { break }
                await self?.consume(data)
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer = buffer[(newline + 1)...]
            guard !lineData.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }
            handle(object)
        }
    }

    private func handle(_ object: [String: Any]) {
        guard let rawID = object["id"],
              let idNumber = (rawID as? Int) ?? (rawID as? String).flatMap(Int.init),
              let continuation = pending.removeValue(forKey: idNumber) else { return }

        if let error = object["error"] as? [String: Any] {
            continuation.resume(throwing: MCPError.rpc(error["message"] as? String ?? "unknown"))
            return
        }

        let result = object["result"] as? [String: Any] ?? [:]
        let json = (try? JSONSerialization.data(withJSONObject: result))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        continuation.resume(returning: json)
    }

    private func request(_ method: String, paramsJSON: String) async throws -> [String: Any] {
        guard let stdin else { throw MCPError.notInitialized(config.name) }
        let id = nextID
        nextID += 1

        var payload: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let paramsData = paramsJSON.data(using: .utf8),
           let params = try? JSONSerialization.jsonObject(with: paramsData) as? [String: Any] {
            payload["params"] = params
        }
        var data = try JSONSerialization.data(withJSONObject: payload)
        data.append(0x0A)

        let json: String = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            stdin.write(data)

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(60))
                await self?.timeout(id)
            }
        }

        guard let resultData = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any] else {
            return [:]
        }
        return object
    }

    private func timeout(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: MCPError.rpc("таймаут 60 с"))
    }

    private func notify(_ method: String) {
        guard let stdin else { return }
        let payload: [String: Any] = ["jsonrpc": "2.0", "method": method]
        guard var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)
        stdin.write(data)
    }

    private func initialize() async throws {
        let params = #"{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"clientInfo":{"name":"HARNES-S","version":"0.1.0"}}"#
        _ = try await request("initialize", paramsJSON: params)
        notify("notifications/initialized")
        initialized = true
    }

    private func listTools() async throws -> [MCPToolDescriptor] {
        var collected: [MCPToolDescriptor] = []
        var cursor: String?

        repeat {
            let params = cursor.map { #"{"cursor":"\#($0)"}"# } ?? "{}"
            let result = try await request("tools/list", paramsJSON: params)
            let tools = result["tools"] as? [[String: Any]] ?? []
            for tool in tools {
                guard let name = tool["name"] as? String else { continue }
                let schema = (tool["inputSchema"] as? [String: Any]) ?? ["type": "object"]
                collected.append(MCPToolDescriptor(
                    server: config.name,
                    name: name,
                    description: (tool["description"] as? String) ?? "",
                    inputSchema: schema.mapValues { AnySendable($0) },
                    exposure: config.exposure
                ))
            }
            cursor = result["nextCursor"] as? String
        } while cursor != nil

        return collected
    }

    func call(name: String, argumentsJSON: String) async throws -> String {
        try await ensureStarted()
        let params = #"{"name":"\#(name)","arguments":\#(argumentsJSON)}"#
        let result = try await request("tools/call", paramsJSON: params)
        if let isError = result["isError"] as? Bool, isError {
            let text = Self.text(from: result["content"])
            return "ОШИБКА: " + text
        }
        return Self.text(from: result["content"])
    }

    private static func text(from content: Any?) -> String {
        guard let items = content as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for item in items {
            switch item["type"] as? String {
            case "text":
                parts.append(item["text"] as? String ?? "")
            case "image":
                parts.append("[изображение \(item["mimeType"] as? String ?? "image")]")
            case "resource":
                parts.append("[ресурс]")
            default:
                continue
            }
        }
        return parts.joined(separator: "\n")
    }

    func shutdown() {
        stdoutTask?.cancel()
        stdoutTask = nil
        process?.terminate()
        process = nil
        stdin = nil
        initialized = false
        cachedTools = []
        for (_, continuation) in pending {
            continuation.resume(throwing: MCPError.rpc("сессия закрыта"))
        }
        pending.removeAll()
    }
}

/// Owns one session per configured server and merges their tools.
actor MCPManager {
    private var sessions: [String: MCPSession] = [:]
    private let configService: MCPService

    init(configService: MCPService) {
        self.configService = configService
    }

    func sessionsSnapshot() async -> [(name: String, running: Bool, tools: Int)] {
        var snapshot: [(name: String, running: Bool, tools: Int)] = []
        for (name, session) in sessions {
            let running = await session.isRunning
            let tools = await session.tools.count
            snapshot.append((name, running, tools))
        }
        return snapshot
    }

    private var cachedDescriptors: [MCPToolDescriptor]?
    private var cachedRevision = -1

    /// Non-blocking view for the request path: never starts a server, never waits for
    /// one. Empty until the background refresh has finished once.
    func cachedTools() -> [MCPToolDescriptor] {
        cachedDescriptors ?? []
    }

    /// Warms the cache without blocking the caller.
    func refreshInBackground() {
        guard !isRefreshing else { return }
        isRefreshing = true
        Task {
            _ = await tools()
            isRefreshing = false
        }
    }

    private var isRefreshing = false

    /// Cached after the first successful call: the descriptors only change when the
    /// configuration changes or a server is restarted.
    func tools() async -> [MCPToolDescriptor] {
        let revision = await configService.revision
        if let cachedDescriptors, revision == cachedRevision { return cachedDescriptors }
        let descriptors = await fetchTools()
        cachedRevision = revision
        if !descriptors.isEmpty {
            cachedDescriptors = descriptors
        }
        return descriptors
    }

    func invalidateTools() {
        cachedDescriptors = nil
    }

    private func fetchTools() async -> [MCPToolDescriptor] {
        guard let servers = try? await configService.list() else { return [] }
        var result: [MCPToolDescriptor] = []

        for server in servers where server.enabled {
            let session = session(for: server)
            do {
                try await session.ensureStarted()
                result.append(contentsOf: await session.tools)
            } catch {
                continue
            }
        }
        return result
    }

    func call(server: String, tool: String, argumentsJSON: String) async throws -> String {
        guard let session = sessions[server] else {
            throw MCPError.serverNotFound(server)
        }
        return try await session.call(name: tool, argumentsJSON: argumentsJSON)
    }

    private func session(for config: MCPServerConfig) -> MCPSession {
        if let existing = sessions[config.name] { return existing }
        let created = MCPSession(config: config)
        sessions[config.name] = created
        return created
    }
}