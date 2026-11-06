import SwiftUI

struct SettingsView: View {
    let services: AppServices?
    @Environment(AppSettings.self) private var settings
    @State private var tab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Основные").tag(0)
                Text("Стиль").tag(1)
                Text("Провайдеры").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            Group {
                if tab == 0 {
                    GeneralSettingsView()
                } else if tab == 1 {
                    StyleSettingsView(services: services)
                } else {
                    ProvidersSettingsView(services: services)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 660, height: 540)
        .tint(Palette.current.accent)
        .preferredColorScheme(.dark)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Вид") {
                LabeledContent("Тема", value: "Copper (тёмная)")

                Picker("Шрифт", selection: $settings.fontFamily) {
                    Text("Nordwand Mono (встроенный)")
                        .tag(AppFont.bundledFamily)
                    Divider()
                    ForEach(AppFont.installedFamilies(), id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .pickerStyle(.menu)

                HStack(spacing: 12) {
                    Text("Размер шрифта")
                    Slider(value: $settings.fontSize, in: 11...20, step: 1)
                    Text("\(Int(settings.fontSize))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 22, alignment: .trailing)
                }

                Toggle("Показывать время сообщений", isOn: $settings.showTimestamps)
            }

            Section("Агент") {
                Toggle("Работать без подтверждений", isOn: $settings.autopilot)
                Text("Инструменты выполняются сразу. Аварийные команды, ломающие систему, блокируются всегда.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Контекст") {
                HStack(spacing: 12) {
                    Text("Автокомпактация")
                    Slider(value: $settings.compactionThresholdPercent, in: 50...95, step: 5)
                    Text("\(Int(settings.compactionThresholdPercent))%")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)
                }
                Text("Порог считается от окна модели. Данные при компакции не удаляются.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}