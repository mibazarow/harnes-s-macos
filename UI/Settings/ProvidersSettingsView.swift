import SwiftUI

struct ProvidersSettingsView: View {
    let services: AppServices?
    @Environment(ProviderDirectory.self) private var directory
    @Environment(AppSettings.self) private var settings
    @Environment(\.theme) private var theme

    @State private var providers: [ProviderModel] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var editing: ProviderModel?
    @State private var deleting: ProviderModel?
    @State private var deleteError: String?
    /// R44: add or rename a model without opening the provider editor.
    @State private var modelDraft: ModelDraft?

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
        .sheet(item: $modelDraft) { draft in
            ModelEditorSheet(draft: draft, providers: providers) { providerID, oldName, newName in
                Task {
                    await saveModel(
                        providerID: providerID,
                        replacing: oldName,
                        with: newName,
                        adding: draft.mode == .add
                    )
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
                    Section("Модели") {
                        modelList(services: services)
                    }
                    Section("Провайдеры") {
                        ForEach(providers) { provider in
                            providerRow(provider, services: services)
                        }
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
                    Text("Отметь модель в списке — она пойдёт в чат и в сжатие.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(Spacing.medium)
                .background(.bar)
            }
        }
    }

    private func providerRow(_ provider: ProviderModel, services: AppServices) -> some View {
        HStack(alignment: .top, spacing: Spacing.offGrid10) {
            Circle()
                .fill(color(for: provider.health))
                .frame(width: Spacing.offGrid6 + Spacing.hairline, height: Spacing.offGrid6 + Spacing.hairline)
                .padding(.top, Spacing.offGrid5)

            VStack(alignment: .leading, spacing: Spacing.offGrid3) {
                Text(provider.name)
                    .fontWeight(.semibold)

                // A host is an address, not prose: it keeps the mono face.
                Text(provider.host)
                    .font(AppFont.mono(Size.iconSmall))
                    .foregroundStyle(.secondary)

                // R45: the list shows the window that will actually be used for this
                // provider's own model, not the raw row value that a known-model entry
                // may override.
                Text("\(provider.summary) · \(resolvedWindow(for: provider).formatted()) контекст")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Menu {
                rowActions(provider, services: services)
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: Size.controlRegular)
        }
        .padding(.vertical, Spacing.tight)
        .contextMenu {
            rowActions(provider, services: services)
        }
    }

    @ViewBuilder
    private func rowActions(_ provider: ProviderModel, services: AppServices) -> some View {
        Button("Изменить") { editing = provider }
        Divider()
        Button("Удалить", role: .destructive) { deleting = provider }
    }

    /// R44: one list of every model of every provider. The check mark *is* the working
    /// model — there is no second picker to keep in sync.
    @ViewBuilder
    private func modelList(services: AppServices) -> some View {
        let choices = ModelSelection.choices(providers)
        if choices.isEmpty {
            Text("Сначала добавь провайдера и загрузи его модели.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            let current = mainModelBinding.wrappedValue
            ForEach(choices) { choice in
                modelRow(choice, current: current, services: services)
            }

            Button {
                modelDraft = ModelDraft(
                    mode: .add,
                    providerID: providers.first?.id ?? "",
                    name: "",
                    originalName: ""
                )
            } label: {
                Label("Добавить модель", systemImage: "plus")
                    .foregroundStyle(theme.accent)
            }
            .buttonStyle(.plain)
            .font(.caption)
        }
    }

    private func modelRow(
        _ choice: ModelChoice,
        current: String,
        services: AppServices
    ) -> some View {
        let isCurrent = choice.id == current
        return HStack(spacing: Spacing.offGrid10) {
            Button {
                select(choice)
            } label: {
                // The mark is the app's accent, not the system blue: settings use the
                // same copper as the chat.
                Image(systemName: isCurrent ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isCurrent ? theme.accent : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isCurrent ? "Эта модель используется" : "Сделать основной")

            // Mono only for the model name: the provider is a label, not an identifier.
            Text(choice.model)
                .font(AppFont.mono(FontSize.transcriptDefault))
                .lineLimit(1)
                .truncationMode(.middle)

            Text(choice.providerName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: Spacing.small)

            Menu {
                Button("Изменить имя…") {
                    modelDraft = ModelDraft(
                        mode: .edit,
                        providerID: choice.providerID,
                        name: choice.model,
                        originalName: choice.model
                    )
                }
                Divider()
                Button("Удалить модель", role: .destructive) {
                    Task { await deleteModel(choice, services: services) }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: Size.controlRegular)
        }
        .padding(.vertical, Spacing.offGrid2)
        .contentShape(Rectangle())
        .onTapGesture { select(choice) }
        .contextMenu {
            Button("Изменить имя…") {
                modelDraft = ModelDraft(
                    mode: .edit,
                    providerID: choice.providerID,
                    name: choice.model,
                    originalName: choice.model
                )
            }
            Button("Удалить модель", role: .destructive) {
                Task { await deleteModel(choice, services: services) }
            }
        }
    }

    /// Marking a row is the choice: the same key the picker used to write.
    private func select(_ choice: ModelChoice) {
        guard settings.mainModel != choice.id else { return }
        settings.mainModel = choice.id
        Task {
            await directory.reload()
            await reload()
        }
    }

    private func deleteModel(_ choice: ModelChoice, services: AppServices) async {
        guard var provider = providers.first(where: { $0.id == choice.providerID }) else { return }
        provider.models.removeAll { $0 == choice.model }
        if provider.defaultModel == choice.model {
            provider.defaultModel = provider.models.first
        }
        if provider.cheapModel == choice.model {
            provider.cheapModel = nil
        }
        do {
            _ = try await services.providers.save(provider)
            // A stale `settings.mainModel` is fine: `mainModelBinding` falls back to the
            // model that will really be sent.
            await directory.reload()
            await reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func saveModel(
        providerID: String,
        replacing oldName: String,
        with newName: String,
        adding: Bool
    ) async {
        guard let services else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var provider = providers.first(where: { $0.id == providerID }) else { return }

        if adding {
            guard !provider.models.contains(trimmed) else { return }
            provider.models.append(trimmed)
        } else {
            guard let index = provider.models.firstIndex(of: oldName) else { return }
            provider.models[index] = trimmed
            if provider.defaultModel == oldName { provider.defaultModel = trimmed }
            if provider.cheapModel == oldName { provider.cheapModel = trimmed }
        }

        do {
            _ = try await services.providers.save(provider)
            // Renaming the working model keeps the mark on it.
            if !adding,
               settings.mainModel == ModelSelection.raw(providerID: providerID, model: oldName) {
                settings.mainModel = ModelSelection.raw(providerID: providerID, model: trimmed)
            }
            await directory.reload()
            await reload()
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// A stale or empty stored value still shows the model that will actually be used,
    /// so the picker never renders blank while a request would succeed.
    private var mainModelBinding: Binding<String> {
        Binding(
            get: {
                if ModelSelection.resolve(settings.mainModel, in: providers) != nil {
                    return settings.mainModel
                }
                guard let fallback = ModelSelection.fallback(providers) else { return "" }
                return ModelSelection.raw(
                    providerID: fallback.provider.id, model: fallback.model
                )
            },
            set: { settings.mainModel = $0 }
        )
    }

    private func resolvedWindow(for provider: ProviderModel) -> Int {
        ModelContextPreferences.resolve(
            providerID: provider.id,
            model: provider.defaultModel ?? provider.models.first ?? "",
            providerWindow: provider.contextWindow
        ).window
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
                        .font(AppFont.mono(FontSize.transcriptDefault))
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

                Section("Подключение и модели") {
                    // Which model is used is chosen once, on the Providers tab. Here the
                    // row only says what this connection offers.
                    if provider.models.isEmpty {
                        TextField("Имя модели", text: modelBinding)
                            .font(AppFont.mono(FontSize.transcriptDefault))
                        Text("Можно ввести вручную или загрузить список кнопкой выше.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Моделей: \(provider.models.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Text("Окно контекста")
                        TextField("", value: $provider.contextWindow, format: .number)
                            .frame(width: Spacing.offGrid32 * 3 + Spacing.offGrid14)
                            .multilineTextAlignment(.trailing)
                            .font(AppFont.mono(FontSize.transcriptDefault))
                        Stepper("", value: $provider.contextWindow, in: 2_000...4_000_000, step: 8_000)
                            .labelsHidden()
                        Text("токенов")
                            .foregroundStyle(.secondary)
                    }

                    // R34.3: what is actually used, and where the number came from.
                    let resolution = ModelContextPreferences.resolve(
                        providerID: provider.id,
                        model: provider.defaultModel ?? provider.models.first ?? "",
                        providerWindow: provider.contextWindow
                    )
                    let budget = ContextComposer().budget(
                        for: resolution.window,
                        thresholdPercent: settings.compactionThresholdPercent
                    )
                    Text("Окно: \(resolution.window.formatted()) · бюджет \(budget.usable.formatted()) "
                        + "(источник: \(resolution.source.label)) · сжатие на \(budget.thresholdTokens.formatted())")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if ModelContextPreferences.isManual(providerID: provider.id) {
                        // R45: the row's own number wins, so "reset" means going back to
                        // the default, which the resolver reads as "ask the model table".
                        Button("Сбросить окно к модели") {
                            ModelContextPreferences.setManual(false, providerID: provider.id)
                            provider.contextWindow = ProviderModel.defaultContextWindow
                        }
                        .font(.caption)
                    }

                    if provider.contextWindow > 300_000 {
                        Label(
                            "Такое окно есть у считанных моделей. Если оно завышено, компактация не включится никогда: она ждёт \(Int(settings.compactionThresholdPercent))% от этого числа. Типичные значения: 128 000 у DeepSeek и большинства Qwen, 200 000 у Claude, 1 000 000 у Gemini.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption)
                        .foregroundStyle(ThemeTokens.copper.warning)
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
                            .font(AppFont.mono(FontSize.transcriptDefault))
                            .frame(width: Spacing.page + Spacing.hairline, alignment: .trailing)
                    }

                    Text("Насколько свободно модель выбирает слова. 0.2 — собранно и по делу; выше — живее, но многословнее. У каждого провайдера своя.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 10) {
                        Text("Цена входа")
                        TextField("0", value: $provider.inputPrice, format: .number.precision(.fractionLength(0...4)))
                            .font(AppFont.mono(FontSize.transcriptDefault))
                            .frame(width: Spacing.offGrid32 * 3)
                        Text("за 1M токенов")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        Text("Цена выхода")
                        TextField("0", value: $provider.outputPrice, format: .number.precision(.fractionLength(0...4)))
                            .font(AppFont.mono(FontSize.transcriptDefault))
                            .frame(width: Spacing.offGrid32 * 3)
                        Text("за 1M токенов")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Необязательно. Если задать, в футере появится потраченная сумма по данным usage каждого запроса. Пусто — стоимость не считается.")
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
            .padding(Spacing.medium)
        }
        .frame(width: Spacing.offGrid32 * 17, height: Spacing.offGrid32 * 16)
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
            provider.contextWindow = ProviderModel.defaultContextWindow
        }
        // R45: the row is the source of truth now, so a number that arrived by any path
        // is kept as written. The old per-provider flag only relabels the same number as
        // "вручную" and would stop a cleared field from falling back to the model table,
        // so it is cleared on save.
        ModelContextPreferences.setManual(false, providerID: provider.id)

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

/// R44: a model being added or renamed from the list. `originalName` is empty for an
/// add, and the name that has to be replaced for an edit.
struct ModelDraft: Identifiable {
    enum Mode {
        case add
        case edit
    }

    let id = UUID()
    let mode: Mode
    let providerID: String
    var name: String
    let originalName: String
}

/// The small sheet behind "Добавить модель" and "Изменить имя…". It touches only the
/// provider's model list, never the connection fields.
struct ModelEditorSheet: View {
    let draft: ModelDraft
    let providers: [ProviderModel]
    let onSave: (_ providerID: String, _ oldName: String, _ newName: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var providerID: String
    @State private var name: String

    init(
        draft: ModelDraft,
        providers: [ProviderModel],
        onSave: @escaping (_ providerID: String, _ oldName: String, _ newName: String) -> Void
    ) {
        self.draft = draft
        self.providers = providers
        self.onSave = onSave
        _providerID = State(initialValue: draft.providerID)
        _name = State(initialValue: draft.name)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            Text(draft.mode == .add ? "Новая модель" : "Имя модели")
                .font(.headline)

            if draft.mode == .add {
                Picker("Провайдер", selection: $providerID) {
                    ForEach(providers) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
            } else if let provider = providers.first(where: { $0.id == draft.providerID }) {
                Text(provider.name)
                    .foregroundStyle(.secondary)
            }

            TextField("Имя модели", text: $name)
                .font(AppFont.mono(FontSize.transcriptDefault))
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Отмена") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Сохранить") {
                    onSave(providerID, draft.originalName, trimmed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmed.isEmpty || providerID.isEmpty)
            }
        }
        .padding(Spacing.large)
        .frame(width: Spacing.offGrid32 * 13)
    }
}
