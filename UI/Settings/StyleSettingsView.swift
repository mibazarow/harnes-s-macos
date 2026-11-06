import SwiftUI

struct StyleSettingsView: View {
    let services: AppServices?

    @State private var mode: StyleMode = .auto
    @State private var manualCard = ""
    @State private var profanityEnabled = true
    @State private var summary = ""
    @State private var savedNote: String?

    var body: some View {
        Form {
            if services == nil {
                Text("База данных недоступна — настройки стиля отключены.")
                    .foregroundStyle(.secondary)
            } else {
                Section("Как отвечать") {
                    Picker("Режим", selection: $mode) {
                        ForEach(StyleMode.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(mode.hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if mode == .manual {
                    Section("Моя карточка стиля") {
                        TextField(
                            "Например: коротко, на ты, с лёгкой иронией",
                            text: $manualCard,
                            axis: .vertical
                        )
                        .lineLimit(2...5)
                        Text("Этот текст идёт в промпт дословно. Оскорбления и сленг-мусор отбрасываются.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Границы") {
                    Toggle("Разрешать лёгкий мат в ответах", isOn: $profanityEnabled)
                    Text("Максимум одно слово за ответ, только как усилитель. Оскорбления не переносятся никогда.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Что изучено") {
                    Text(summary.isEmpty ? "Пока нет данных." : summary)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    HStack {
                        Button("Обновить") { Task { await reload() } }
                        Button("Сбросить профиль", role: .destructive) {
                            Task {
                                await services?.style.reset()
                                await reload()
                                savedNote = "Профиль сброшен."
                            }
                        }
                    }
                }

                if let savedNote {
                    Text(savedNote)
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .formStyle(.grouped)
        .tint(Palette.current.accent)
        .task { await reload() }
        .onChange(of: mode) { _, _ in Task { await save() } }
        .onChange(of: profanityEnabled) { _, _ in Task { await save() } }
        .onChange(of: manualCard) { _, _ in Task { await save() } }
    }

    private func reload() async {
        guard let store = services?.style else { return }
        let profile = await store.current()
        mode = profile.mode
        manualCard = profile.manualCard ?? ""
        profanityEnabled = profile.profanityEnabled
        summary = await store.summary()
    }

    private func save() async {
        guard let store = services?.style else { return }
        await store.setMode(mode)
        await store.setManualCard(manualCard)
        await store.setProfanityEnabled(profanityEnabled)
        summary = await store.summary()
        savedNote = "Сохранено."
    }
}
