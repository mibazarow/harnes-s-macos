import AppKit
import Foundation
import Observation
import os

struct AppServices: Sendable {
    let database: AppDatabase
    let providers: ProvidersService
    let secrets: SecretsService
    let memory: MemoryService
    let embeddings: EmbeddingsService
    let history: ChatHistoryService
    let compaction: CompactionService
    let indexer: WorkspaceIndexer
    let scheduler: SchedulerService
    let fileSafety: FileSafetyService
    let todos: TodoStore
    let style: StyleStore
    let skills: SkillsService
    let mcp: MCPService
    let mcpManager: MCPManager
    /// Installs the embedding model into the data folder after a fresh install.
    let modelInstaller: EmbeddingModelInstaller?

    init(database: AppDatabase, modelInstaller: EmbeddingModelInstaller? = nil) {
        self.database = database
        let providers = ProvidersService(database: database)
        self.providers = providers
        self.secrets = SecretsService(database: database)
        self.memory = MemoryService(database: database)
        self.modelInstaller = modelInstaller
        self.embeddings = EmbeddingsService(database: database, installer: modelInstaller)
        self.history = ChatHistoryService(database: database)
        self.compaction = CompactionService()
        self.indexer = WorkspaceIndexer(
            database: database,
            memory: self.memory,
            embeddings: self.embeddings
        )
        self.scheduler = SchedulerService(database: database)
        self.fileSafety = FileSafetyService(database: database)
        self.todos = TodoStore(database: database)
        self.style = StyleStore(database: database)
        self.skills = SkillsService()
        let mcpConfig = MCPService()
        self.mcp = mcpConfig
        self.mcpManager = MCPManager(configService: mcpConfig)
    }

    @MainActor
    static func live() -> AppServices? {
        do {
            // The test bundle launches this app as its host, so without this guard a
            // plain `xcodebuild test` would migrate and write to the user's real
            // database.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                return AppServices(database: try AppDatabase(inMemory: true))
            }
            try AppPaths.bootstrap()
            let database = try AppDatabase(path: AppPaths.databaseURL)
            let services = AppServices(database: database, modelInstaller: EmbeddingModelInstaller())
            Task.detached(priority: .utility) {
                if let pruned = try? await services.memory.pruneUnused(), pruned > 0 {
                    Logger(subsystem: "app.project-s.swift", category: "memory")
                        .info("Память: удалено \(pruned, privacy: .public) неиспользуемых записей")
                }
                try? await services.memory.pruneOrphanEmbeddings()
            }
            return services
        } catch {
            Logger(subsystem: "app.project-s.swift", category: "storage")
                .error("Не удалось открыть базу данных: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

@MainActor
@Observable
final class AppModel {
    let settings: AppSettings
    let services: AppServices?
    let chat: ChatStore
    let providerDirectory: ProviderDirectory

    init() {
        let settings = AppSettings()
        let services = AppServices.live()
        self.settings = settings
        self.services = services
        self.chat = ChatStore(services: services)
        self.providerDirectory = ProviderDirectory(service: services?.providers)

        if let services {
            // MCP servers are child processes; without this they survive the app.
            NotificationCenter.default.addObserver(
                forName: NSApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { _ in
                let done = DispatchSemaphore(value: 0)
                Task.detached(priority: .userInitiated) {
                    await services.mcpManager.shutdownAll()
                    done.signal()
                }
                _ = done.wait(timeout: .now() + 2)
            }
        }
    }
}