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

    init(database: AppDatabase) {
        self.database = database
        let providers = ProvidersService(database: database)
        self.providers = providers
        self.secrets = SecretsService(database: database)
        self.memory = MemoryService(database: database)
        self.embeddings = EmbeddingsService(database: database, providers: providers)
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

    static func live() -> AppServices? {
        do {
            try AppPaths.bootstrap()
            let database = try AppDatabase(path: AppPaths.databaseURL)
            let services = AppServices(database: database)
            Task.detached(priority: .utility) {
                if let pruned = try? await services.memory.pruneUnused(), pruned > 0 {
                    Logger(subsystem: "app.project-s.swift", category: "memory")
                        .info("Память: удалено \(pruned, privacy: .public) неиспользуемых записей")
                }
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
    }
}