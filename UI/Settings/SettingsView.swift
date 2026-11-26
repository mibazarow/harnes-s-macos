import SwiftUI

struct SettingsView: View {
    let services: AppServices?
    @Environment(AppSettings.self) private var settings

    @State private var tab = Tab.general

    private enum Tab: Hashable {
        case general, style, providers
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettingsView()
                .tabItem { Label("Основные", systemImage: "gearshape") }
                .tag(Tab.general)

            StyleSettingsView(services: services)
                .tabItem { Label("Стиль", systemImage: "textformat") }
                .tag(Tab.style)

            ProvidersSettingsView(services: services)
                .tabItem { Label("Провайдеры", systemImage: "server.rack") }
                .tag(Tab.providers)
        }
        // The native settings window sizes itself; a fixed frame breaks it when the
        // system font changes.
        .frame(minWidth: Layout.settingsWidth, minHeight: Layout.settingsHeight)
        .theme(settings.theme.tokens)
        .tint(settings.theme.tokens.accent)
        .preferredColorScheme(settings.theme.tokens.scheme)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section {
                Picker("Тема", selection: $settings.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.title).tag(theme)
                    }
                }

                Toggle("Моноширинный интерфейс", isOn: $settings.monoInterface)
                Text("По умолчанию интерфейс набран системным SF Pro; код и пути всегда моноширинные. Включите, чтобы вернуть Nordwand Mono всему интерфейсу.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Шрифт кода", selection: $settings.fontFamily) {
                    Text("Nordwand Mono (встроенный)")
                        .tag(AppFont.bundledFamily)
                    Divider()
                    ForEach(AppFont.installedFamilies(), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: Spacing.medium) {
                    Text("Размер шрифта чата")
                    Slider(
                        value: $settings.fontSize,
                        in: FontSize.transcriptMin...FontSize.transcriptMax,
                        step: 1
                    )
                    Text("\(Int(settings.fontSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: Spacing.offGrid28, alignment: .trailing)
                }
                Text("Масштабирует только транскрипт: тулбар и настройки живут в системном размере.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Показывать время сообщений", isOn: $settings.showTimestamps)
            } header: {
                Text("Внешний вид")
            }

            Section {
                Toggle("Работать без подтверждений", isOn: $settings.autopilot)
                Text("Инструменты выполняются сразу. Аварийные команды, ломающие систему, блокируются всегда.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Агент")
            }

            Section {
                HStack(spacing: Spacing.medium) {
                    Text("Автокомпактация")
                    Slider(value: $settings.compactionThresholdPercent, in: 50...95, step: 5)
                    Text("\(Int(settings.compactionThresholdPercent))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: Spacing.offGrid38, alignment: .trailing)
                }
                Text("Порог считается от окна модели. Данные при компакции не удаляются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Контекст")
            }
        }
        .formStyle(.grouped)
    }
}
