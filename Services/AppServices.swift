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
    let usage: UsageService
    let skills: SkillsService
    let mcp: MCPService
    let mcpManager: MCPManager
    /// Session-scoped "read before write" state shared by every turn.
    let fileLedger = FileReadingLedger()
    /// Tool restriction from the last skill read in this session/turn.
    let skillScope = ActiveSkillScope()
    /// R20.4: the project root, shared by every registry so `workspace set` applies to
    /// the tools of the same turn.
    let workspaceState = WorkspaceState(AppPaths.workspaceDirectory)
    /// R30.5: mutating actions claim a row before they run.
    let operations: OperationLedger
    /// R30.6: the auditable trail of steps.
    let actions: ActionJournal
    /// Installs the embedding model into the data folder after a fresh install.
    let modelInstaller: EmbeddingModelInstaller?

    init(database: AppDatabase, modelInstaller: EmbeddingModelInstaller? = nil) {
        self.database = database
        self.operations = OperationLedger(database: database)
        self.actions = ActionJournal(database: database)
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
        self.usage = UsageService(database: database)
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

        // R30.6: retention at launch — old rows go to a CSV, then out of the database.
        if let services {
            Task.detached(priority: .utility) {
                _ = try? await services.actions.archiveAndPrune()
            }
        }

        // R25.2: the layout at launch is the known-good state for `display restore_last`.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            DisplayLayoutStore.save(DisplayControl.layout())
        }

        // R18.11: system-wide stop for a runaway GUI loop. If the combination is taken,
        // the app still stops from the Stop button; the hotkey is reported, not faked.
        let hotkeyInstalled = GlobalStopHotkey.shared.install {
            AgentAbortSignal.shared.abort("hotkey \(GlobalStopHotkey.label)")
            UIActionJournal.append([
                "at": ISO8601DateFormatter().string(from: Date()),
                "tool": "hotkey",
                "args": GlobalStopHotkey.label,
                "result": "abort",
                "head": "аварийный стоп"
            ])
            NotificationCenter.default.post(name: .harnessAbortRequested, object: nil)
        }
        if !hotkeyInstalled {
            ChatStore.logLatency("hotkey_failed combo=\(GlobalStopHotkey.label) reason=taken")
        }

        NotificationCenter.default.addObserver(
            forName: .harnessAbortRequested, object: nil, queue: .main
        ) { [chat] _ in
            chat.stop()
        }

        // R27.1: the assistant chord opens a panel with the selected text of the app the
        // person was in. A taken combination is logged, not silently replaced.
        HotkeyPanelController.shared.excludedBundleIDs = UserDefaults.standard
            .string(forKey: "harness.hotkey.excluded")?
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        let assistantInstalled = AssistantHotkey.shared.install(HotkeyConfig.default) { [chat] in
            Task { @MainActor in
                HotkeyPanelController.shared.show { text, context in
                    var message = text
                    if let selected = context.selectedText {
                        message += "\n\nВыделенный текст из \(context.appName):\n\(selected)"
                    }
                    chat.send(message)
                }
            }
        }
        if !assistantInstalled {
            ChatStore.logLatency("hotkey_failed combo=\(HotkeyConfig.default.label) reason=taken")
        }

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