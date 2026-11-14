import Foundation

enum MCPTransport: String, Codable, Sendable, CaseIterable {
    case stdio
    case http
    case sse
}

struct MCPServerConfig: Codable, Identifiable, Sendable, Equatable {
    var name: String
    var transport: MCPTransport
    var command: String?
    var args: [String]?
    var url: String?
    var env: [String: String]?
    var exposure: String
    var enabled: Bool
    var scope: String
    /// Servers that only read (docs search, web lookups) stay available in plan mode.
    /// Defaults to false: an unknown server is treated as able to mutate.
    var isReadOnly: Bool

    var id: String { name }

    init(
        name: String,
        transport: MCPTransport,
        command: String? = nil,
        args: [String]? = nil,
        url: String? = nil,
        env: [String: String]? = nil,
        exposure: String = "deferred",
        enabled: Bool = true,
        scope: String = "global",
        isReadOnly: Bool = false
    ) {
        self.name = name
        self.transport = transport
        self.command = command
        self.args = args
        self.url = url
        self.env = env
        self.exposure = exposure
        self.enabled = enabled
        self.scope = scope
        self.isReadOnly = isReadOnly
    }

    /// Hand-written because `isReadOnly` is newer than the config files on disk:
    /// `decodeIfPresent` keeps existing configs loadable and defaults to "can mutate".
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        transport = try container.decode(MCPTransport.self, forKey: .transport)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        args = try container.decodeIfPresent([String].self, forKey: .args)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        env = try container.decodeIfPresent([String: String].self, forKey: .env)
        exposure = try container.decodeIfPresent(String.self, forKey: .exposure) ?? "deferred"
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        scope = try container.decodeIfPresent(String.self, forKey: .scope) ?? "global"
        isReadOnly = try container.decodeIfPresent(Bool.self, forKey: .isReadOnly) ?? false
    }

    var summary: String {
        switch transport {
        case .stdio:
            let parts = [command ?? ""] + (args ?? [])
            return parts.filter { !$0.isEmpty }.joined(separator: " ")
        case .http, .sse:
            return url ?? ""
        }
    }
}

struct MCPConfigFile: Codable, Sendable {
    var servers: [MCPServerConfig]
}

actor MCPService {
    private let configURL: URL
    /// Bumped on every write so readers can tell whether their cache is stale.
    private(set) var revision = 0

    init(configURL: URL = AppPaths.mcpConfigURL) {
        self.configURL = configURL
    }

    func list() throws -> [MCPServerConfig] {
        try load().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func add(_ server: MCPServerConfig, force: Bool = false) throws {
        var servers = try load()
        if let index = servers.firstIndex(where: { $0.name == server.name }) {
            guard force else {
                throw ConfigurationError.alreadyExists(server.name)
            }
            servers[index] = server
        } else {
            servers.append(server)
        }
        try save(servers)
    }

    func remove(name: String) throws {
        var servers = try load()
        guard let index = servers.firstIndex(where: { $0.name == name }) else {
            throw ConfigurationError.notFound(name)
        }
        servers.remove(at: index)
        try save(servers)
    }

    func setEnabled(name: String, enabled: Bool) throws {
        var servers = try load()
        guard let index = servers.firstIndex(where: { $0.name == name }) else {
            throw ConfigurationError.notFound(name)
        }
        servers[index].enabled = enabled
        try save(servers)
    }

    private func load() throws -> [MCPServerConfig] {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return []
        }
        let data = try Data(contentsOf: configURL)
        return try JSONDecoder().decode(MCPConfigFile.self, from: data).servers
    }

    private func save(_ servers: [MCPServerConfig]) throws {
        try AppPaths.ensureDirectory(configURL.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(MCPConfigFile(servers: servers))
        try data.write(to: configURL, options: .atomic)
        revision += 1
    }
}