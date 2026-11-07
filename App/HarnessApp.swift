import SwiftUI

@main
struct HarnessApp: App {
    @State private var model = AppModel()

    init() {
        #if DEBUG
        // Headless contract export for the Windows port; never reached in Release.
        if ContractExporter.handleCommandLine() { return }
        #endif
        AppFont.register()
    }

    var body: some Scene {
        WindowGroup("HARNES-S") {
            RootView(services: model.services)
                .environment(model.settings)
                .environment(model.chat)
                .environment(model.providerDirectory)
        }
        .defaultSize(width: 980, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Агент") {
                Button("Остановить") {
                    model.chat.stop()
                }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!model.chat.isStreaming)

                Divider()

                Button(model.chat.isPlanMode ? "Выключить режим плана" : "Режим плана (только чтение)") {
                    model.chat.setPlanMode(!model.chat.isPlanMode)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Очистить план") {
                    model.services?.todos.clear()
                }

                Divider()

                Button("Очистить вид") {
                    model.chat.clearView()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(services: model.services)
                .environment(model.settings)
                .environment(model.providerDirectory)
        }
    }
}