import SwiftUI

struct RootView: View {
    let services: AppServices?

    @Environment(AppSettings.self) private var settings
    @Environment(ChatStore.self) private var chat
    @Environment(ProviderDirectory.self) private var providerDirectory
    @State private var draft = ""
    @State private var composerHeight: CGFloat = Size.composerMin
    @State private var attachments: [ChatAttachment] = []
    /// Set while the user drags a window edge; rows drop text selection for the drag.
    @State private var liveResize = LiveResizeState()

    private var tokens: ThemeTokens { settings.theme.tokens }

    var body: some View {
        // The context numbers come from a snapshot, not from the plan: reading the plan
        // here subscribed the whole screen — including the composer and the stop ring —
        // to `messages`, and every paint tick re-evaluated it.
        let usage = chat.statusPressure()

        VStack(spacing: Spacing.zero) {
            TranscriptView(
                fontSize: settings.fontSize,
                showTimestamps: settings.showTimestamps
            )

            if let services, !services.todos.items.isEmpty {
                PlanBar(todos: services.todos, fontSize: settings.fontSize)
            }

            ComposerView(
                text: $draft,
                height: $composerHeight,
                attachments: $attachments,
                fontSize: settings.fontSize,
                isStreaming: chat.isStreaming,
                queuedCount: chat.queuedCount,
                providerLabel: providerDirectory.label,
                contextLabel: contextLabel(for: usage),
                contextWarning: usage?.overThreshold ?? false,
                modelLabel: modelLabel,
                modelWarning: modelWarning,
                spent: chat.spent,
                onSend: send,
                onStop: chat.stop
            )
        }
        .background(tokens.contentBackground)
        .background(
            WindowResizeBridge(state: liveResize)
                .frame(width: Spacing.zero, height: Spacing.zero)
        )
        .environment(\.theme, tokens)
        .environment(liveResize)
        .tint(tokens.accent)
        // `nil` means "follow the system appearance" — the .system and .copper themes
        // must not pin a scheme.
        .preferredColorScheme(tokens.scheme)
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("HARNES-S")
        .navigationSubtitle(providerDirectory.label)
        .toolbar { toolbarContent }
        // The navigation layer is glass; the content layer stays solid.
        .toolbarBackground(.ultraThinMaterial, for: .windowToolbar)
        .task {
            #if DEBUG
            if DemoTranscript.scenario != nil { return }
            #endif
            chat.autopilot = settings.autopilot
            chat.compactionThreshold = settings.compactionThresholdPercent
            services?.modelInstaller?.startIfNeeded()
            await chat.loadHistory()
            await providerDirectory.reload()
            chat.refreshContextUsage(contextWindow: providerDirectory.contextWindow ?? 128_000)
            await chat.warmUpMCP()
            startScheduler()
        }
        .onChange(of: services?.modelInstaller?.phase) { oldValue, newValue in
            guard let newValue else { return }
            switch newValue {
            case .ready where oldValue?.isDownloading == true:
                chat.notice("Модель эмбеддингов скачана. Семантический поиск по памяти и рабочей папке включён.")
            case .failed(let reason):
                chat.notice("Модель эмбеддингов не скачалась: \(reason). Поиск пока работает по ключевым словам; загрузка повторится при следующем запуске.")
            default:
                break
            }
        }
        .onChange(of: settings.autopilot) { _, newValue in
            chat.autopilot = newValue
        }
        .onChange(of: settings.compactionThresholdPercent) { _, newValue in
            chat.compactionThreshold = newValue
            chat.refreshContextUsage(contextWindow: providerDirectory.contextWindow ?? 128_000)
        }
        .onChange(of: providerDirectory.contextWindow) { oldValue, newValue in
            guard let oldValue, let newValue, newValue < oldValue else {
                if let newValue { chat.refreshContextUsage(contextWindow: newValue) }
                return
            }
            let used = chat.contextUsage?.usedTokens ?? 0
            let threshold = Int(Double(newValue) * settings.compactionThresholdPercent / 100)
            guard used > threshold else { return }
            chat.notice("Окно контекста уменьшилось: \(oldValue) → \(newValue) токенов. Сейчас в истории ~\(used). При следующем ответе старые сообщения свернутся в саммари; из базы ничего не удалится.")
        }
    }

    /// Native chrome: the window keeps its own title bar, so dragging, Full Screen, zoom
    /// and Stage Manager work without a hand-drawn header.
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // S4: only the fact that a child is working. Finished children lose their
            // pill immediately; the report arrives in the transcript.
            SubagentPills(agents: chat.runningSubagents)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            if chat.isStreaming {
                Button {
                    chat.stop()
                } label: {
                    Label("Остановить", systemImage: "stop.fill")
                }
                .help("Остановить ответ (Esc)")
                .tint(tokens.destructive)
            }

            Button {
                chat.setPlanMode(!chat.isPlanMode)
            } label: {
                Label(
                    chat.isPlanMode ? "Выключить режим плана" : "Режим плана",
                    systemImage: chat.isPlanMode ? "eye.slash" : "eye"
                )
            }
            .help(chat.isPlanMode ? "Выключить режим плана" : "Режим плана: только чтение")

            SettingsLink {
                Label("Настройки", systemImage: "gearshape")
            }
            .help("Настройки (⌘,)")
        }
    }

    private var modelLabel: String? {
        #if DEBUG
        // Demo screenshots show a finished, working install — not a download in flight.
        if DemoTranscript.scenario != nil { return nil }
        #endif
        guard let installer = services?.modelInstaller else { return nil }
        switch installer.phase {
        case .checking, .ready:
            return nil
        case .downloading(let received, let total):
            let percent = total > 0 ? Int(Double(received) / Double(total) * 100) : 0
            return "эмбеддинги \(percent)%"
        case .failed:
            return "эмбеддинги: ошибка загрузки"
        }
    }

    private var modelWarning: Bool {
        if case .failed = services?.modelInstaller?.phase { true } else { false }
    }

    private func startScheduler() {
        guard let services else { return }
        try? services.scheduler.bootstrap()
        try? services.scheduler.ensureMemoryReportSchedule()
        services.scheduler.onMemoryReport = {
            guard await !chat.isStreaming else { return false }
            do {
                let report = try await services.memory.maintenanceReport()
                guard await !chat.isStreaming else { return false }
                let url = try MemoryService.saveReport(report, directory: AppPaths.dataDirectory)
                await chat.notice("Отчёт памяти: \(report.components(separatedBy: "\n").dropFirst(2).first ?? "готов")\n\(url.path)")
                return true
            } catch {
                ChatStore.logLatency("memory-report failed: \(error.localizedDescription)")
                return false
            }
        }
        services.scheduler.onFire = { task in
            Task { @MainActor in
                chat.send(task.prompt)
            }
        }
        services.scheduler.start()
    }

    private func contextLabel(for usage: ContextUsage?) -> String {
        guard let usage else { return "— / —" }
        let used = Self.shortTokens(usage.usedTokens)
        let window = Self.shortTokens(usage.contextWindow)
        if usage.compacted > 0 {
            return "\(usage.percent)% · \(used) / \(window) · сжато \(usage.compacted)"
        }
        return "\(usage.percent)% · \(used) / \(window)"
    }

    private static func shortTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
        if value >= 1_000 {
            return "\(value / 1_000)k"
        }
        return "\(value)"
    }

    private func send() {
        let text = draft
        let files = attachments
        draft = ""
        composerHeight = Size.composerMin
        attachments = []
        chat.send(text, attachments: files)
    }
}

struct PlanBar: View {
    let todos: TodoStore
    let fontSize: CGFloat

    @Environment(\.theme) private var theme
    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: Spacing.offGrid6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                    Text("план · \(todos.items.filter { $0.status == "done" }.count)/\(todos.items.count)")
                    Spacer(minLength: Spacing.zero)
                    Button {
                        todos.clear()
                    } label: {
                        Image(systemName: "xmark")
                            .imageScale(.small)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Убрать план")
                    .accessibilityLabel("Убрать план")
                }
                .font(.caption)
                .foregroundStyle(theme.labelSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(todos.items) { item in
                    HStack(alignment: .top, spacing: Spacing.offGrid6) {
                        Text(mark(item.status))
                            .foregroundStyle(color(item.status))
                        Text(item.text)
                            .foregroundStyle(item.status == "done" ? theme.labelTertiary : theme.labelPrimary)
                            .strikethrough(item.status == "done", color: theme.labelTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(AppFont.ui(max(fontSize - 2, FontSize.minReadable)))
                }
            }
        }
        .padding(.horizontal, Spacing.offGrid20)
        .padding(.vertical, Spacing.small)
        .frame(maxWidth: Layout.chatContainer, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(theme.controlBackground)
        .overlay(alignment: .top) {
            Rectangle().fill(theme.separator).frame(height: Spacing.hairline)
        }
    }

    private func mark(_ status: String) -> String {
        switch status {
        case "done": "[x]"
        case "active", "in_progress": "[~]"
        case "cancelled": "[-]"
        default: "[ ]"
        }
    }

    private func color(_ status: String) -> Color {
        switch status {
        case "done": theme.labelTertiary
        case "active", "in_progress": theme.accent
        case "cancelled": theme.destructive
        default: theme.labelSecondary
        }
    }
}
