import SwiftUI

struct ProvidersSettingsView: View {
    let services: AppServices?
    @Environment(ProviderDirectory.self) private var directory

    @State private var providers: [ProviderModel] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var editing: ProviderModel?
    @State private var deleting: ProviderModel?
    @State private var deleteError: String?

    var body: some View {
        Group {
            if let services {
                content(services: services)
            } else {
                ContentUnavailableView(
                    "База данных недоступна",
                    systemImage: "exclamationmark.triangle",
                    description: Text("Провайдеров нельзя сохранить, пока не открывается локальная база.")
                )
            }
        }
        .task(id: services == nil) {
            await reload()
        }
        .sheet(item: $editing) { provider in
            if let services {
                ProviderEditorView(provider: provider, service: services.providers) {
                    Task { await reload() }
                }
            }
        }
        .confirmationDialog(
            "Удалить провайдера «\(deleting?.name ?? "")»?",
            isPresented: Binding(
                get: { deleting != nil },
                set: { if !$0 { deleting = nil } }
            )
        ) {
            Button("Удалить", role: .destructive) {
                if let provider = deleting {
                    Task { await delete(provider) }
                }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Токен и модели этого провайдера будут удалены из базы.")
        }
    }

    @ViewBuilder
    private func content(services: AppServices) -> some View {
        VStack(spacing: 0) {
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }
            if let deleteError {
                Text(deleteError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if providers.isEmpty {
                ContentUnavailableView {
                    Label("Провайдеров нет", systemImage: "server.rack")
                } description: {
                    Text("Добавь любой OpenAI-совместимый endpoint: название, Base URL и токен.")
                } actions: {
                    Button("Добавить провайдера") {
                        editing = ProviderModel()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(providers) { provider in
                        providerRow(provider, services: services)
                    }
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !providers.isEmpty {
                HStack {
                    Button {
                        editing = ProviderModel()
                    } label: {
                        Label("Добавить", systemImage: "plus")
                    }
                    Spacer()
                    if let defaultProvider = providers.first(where: \.isDefault) {
                        Text("основной: \(defaultProvider.name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(12)
                .background(.bar)
            }
        }
    }

    private func providerRow(_ provider: ProviderModel, services: AppServices) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(color(for: provider.health))
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(provider.name)
                        .fontWeight(.semibold)
                    if provider.isDefault {
                        Text("default")
                            .font(AppFont.mono(9, weight: .medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                    }
                }

                Text(provider.host)
                    .font(AppFont.mono(11))
                    .foregroundStyle(.secondary)

                Text("\(provider.summary) · \(provider.contextWindow.formatted()) контекст")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                rowActions(provider, services: services)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
        }
        .padding(.vertical, 4)
        .contextMenu {
            rowActions(provider, services: services)
        }
    }

    @ViewBuilder
    private func rowActions(_ provider: ProviderModel, services: AppServices) -> some View {
        Button("Изменить") { editing = provider }
        if !provider.isDefault {
            Button("Сделать основным") {
                Task { await makeDefault(provider, services: services) }
            }
        }
        Divider()
        Button("Удалить", role: .destructive) { deleting = provider }
    }

    private func color(for health: String) -> Color {
        switch health {
        case "ok": .green
        case "error": .red
        default: .secondary
        }
    }

    private func reload() async {
        guard let services else {
            loading = false
            return
        }
        loading = true
        errorText = nil
        do {
            providers = try await services.providers.list()
            await directory.reload()
        } catch {
            errorText = error.localizedDescription
        }
        loading = false
    }

    private func makeDefault(_ provider: ProviderModel, services: AppServices) async {
        do {
            try await services.providers.setDefault(id: provider.id)
            await reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func delete(_ provider: ProviderModel) async {
        guard let services else { return }
        deleting = nil
        do {
            try await services.providers.delete(id: provider.id)
            await reload()
        } catch {
            deleteError = error.localizedDescription
        }
    }
}

struct ProviderEditorView: View {
    let service: ProvidersService
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSettings.self) private var settings

    @State private var provider: ProviderModel
    @State private var testing = false
    @State private var saving = false
    @State private var message: String?
    @State private var isError = false

    init(provider: ProviderModel, service: ProvidersService, onSaved: @escaping () -> Void) {
        self.service = service
        self.onSaved = onSaved
        _provider = State(initialValue: provider)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Подключение") {
                    TextField("Название", text: $provider.name)
                    TextField("Base URL", text: $provider.baseURL, prompt: Text("https://api.example.com/v1"))
                        .font(AppFont.mono(13))
                    SecureField("Токен", text: $provider.apiKey)

                    HStack(spacing: 10) {
                        Button("Проверить и загрузить модели") {
                            Task { await fetchModels() }
                        }
                        .disabled(testing || provider.baseURL.isEmpty)

                        if testing {
                            ProgressView()
                                .controlSize(.small)
                        }

                        if let message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(isError ? .red : .green)
                        }
                    }
                }

                Section("Модель") {
                    if provider.models.isEmpty {
                        TextField("Имя модели", text: modelBinding)
                            .font(AppFont.mono(13))
                    } else {
                        Picker("Модель", selection: modelBinding) {
                            ForEach(provider.models, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    HStack(spacing: 10) {
                        Text("Окно контекста")
                        TextField("", value: $provider.contextWindow, format: .number)
                            .frame(width: 110)
                            .multilineTextAlignment(.trailing)
                            .font(AppFont.mono(13))
                        Stepper("", value: $provider.contextWindow, in: 2_000...4_000_000, step: 8_000)
                            .labelsHidden()
                        Text("токенов")
                            .foregroundStyle(.secondary)
                    }

                    Picker("Уровень размышлений", selection: $provider.reasoningLevel) {
                        ForEach(ReasoningLevel.allCases) { level in
                            Text(level.title).tag(level)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Выключено, минимальный, средний или максимальный. Передаётся провайдеру как reasoning effort.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Text("Температура")
                        Slider(
                            value: $provider.temperature,
                            in: ProviderModel.temperatureRange,
                            step: 0.05
                        )
                        Text(provider.temperature.formatted(.number.precision(.fractionLength(2))))
                            .font(AppFont.mono(13))
                            .frame(width: 42, alignment: .trailing)
                    }

                    Text("Насколько свободно модель выбирает слова. 0.2 — собранно и по делу; выше — живее, но многословнее. У каждого провайдера своя.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text("Автокомпактация: \(Int(settings.compactionThresholdPercent))% окна (меняется в «Основных»)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Toggle("Провайдер по умолчанию", isOn: $provider.isDefault)
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(saving ? "Сохранение…" : "Сохранить") {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || provider.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .frame(width: 540, height: 500)
        .interactiveDismissDisabled(saving)
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { provider.defaultModel ?? provider.models.first ?? "" },
            set: { provider.defaultModel = $0 }
        )
    }

    private func fetchModels() async {
        testing = true
        message = nil
        isError = false
        defer { testing = false }

        do {
            let models = try await service.fetchModels(
                baseURL: provider.baseURL,
                apiKey: provider.apiKey
            )
            provider.models = models
            if provider.defaultModel == nil || !models.contains(provider.defaultModel ?? "") {
                provider.defaultModel = models.first
            }
            provider.health = "ok"
            provider.lastCheckAt = Timestamps.now()
            message = "Найдено моделей: \(models.count)"
        } catch {
            provider.health = "error"
            isError = true
            message = error.localizedDescription
        }
    }

    private func save() async {
        saving = true
        message = nil
        isError = false
        defer { saving = false }

        if provider.contextWindow < 1_000 {
            provider.contextWindow = 128_000
        }

        if provider.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            provider.name = URL(string: provider.baseURL)?.host ?? provider.baseURL
        }

        do {
            _ = try await service.save(provider)
            onSaved()
            dismiss()
        } catch {
            isError = true
            message = error.localizedDescription
        }
    }
}