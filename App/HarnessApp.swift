import SwiftUI

@main
struct HarnessApp: App {
    @State private var model = AppModel()

    init() {
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
        // Native chrome: the toolbar belongs to the window, so dragging, zoom,
        // Full Screen and Stage Manager all work without a hand-drawn header.
        .windowToolbarStyle(.unified)
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

                Divider()

                // R33: find over the visible transcript.
                Button("Найти в чате") {
                    model.chat.search.present()
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Найти следующее") {
                    model.chat.search.next()
                }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!model.chat.search.hasMatches)

                Button("Найти предыдущее") {
                    model.chat.search.previous()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!model.chat.search.hasMatches)

                Divider()

                // R34: the command palette.
                Button("Палитра команд") {
                    model.chat.palette.toggle()
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }

        Settings {
            SettingsView(services: model.services)
                .environment(model.settings)
                .environment(model.providerDirectory)
        }
    }
}