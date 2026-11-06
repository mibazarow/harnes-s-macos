import SwiftUI

struct RootView: View {
    let services: AppServices?

    @Environment(AppSettings.self) private var settings
    @Environment(ChatStore.self) private var chat
    @Environment(ProviderDirectory.self) private var providerDirectory
    @State private var draft = ""
    @State private var composerHeight: CGFloat = 24
    @State private var attachments: [ChatAttachment] = []

    private var palette: Palette { Palette.current }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(palette: palette, planMode: chat.isPlanMode)

            TranscriptView(
                palette: palette,
                fontSize: settings.fontSize,
                lineSpacing: settings.lineSpacing,
                showTimestamps: settings.showTimestamps
            )

            if let services, !services.todos.items.isEmpty {
                PlanBar(todos: services.todos, palette: palette, fontSize: settings.fontSize)
            }

            ComposerView(
                text: $draft,
                height: $composerHeight,
                attachments: $attachments,
                palette: palette,
                fontSize: settings.fontSize,
                isStreaming: chat.isStreaming,
                queuedCount: chat.queuedCount,
                providerLabel: providerDirectory.label,
                contextLabel: contextLabel,
                contextWarning: contextPlan.isOverThreshold,
                onSend: send,
                onStop: chat.stop
            )
        }
        .background(palette.background)
        .tint(palette.accent)
        .preferredColorScheme(.dark)
        .frame(minWidth: 560, minHeight: 420)
        .task {
            chat.autopilot = settings.autopilot
            await chat.loadHistory()
            await providerDirectory.reload()
            await chat.warmUpMCP()
            startScheduler()
        }
        .onChange(of: settings.autopilot) { _, newValue in
            chat.autopilot = newValue
        }
        .onChange(of: providerDirectory.contextWindow) { oldValue, newValue in
            guard let oldValue, let newValue, newValue < oldValue else { return }
            let used = contextPlan.usedTokens
            let threshold = Int(Double(newValue) * settings.compactionThresholdPercent / 100)
            guard used > threshold else { return }
            chat.notice("Окно контекста уменьшилось: \(oldValue) → \(newValue) токенов. Сейчас в истории ~\(used). При следующем ответе старые сообщения свернутся в саммари; из базы ничего не удалится.")
        }
    }

    private func startScheduler() {
        guard let services else { return }
        try? services.scheduler.bootstrap()
        services.scheduler.onFire = { task in
            Task { @MainActor in
                chat.send(task.prompt)
            }
        }
        services.scheduler.start()
    }

    private var contextPlan: ContextPlan {
        chat.contextPlan(
            contextWindow: providerDirectory.contextWindow ?? 128_000,
            thresholdPercent: settings.compactionThresholdPercent
        )
    }

    private var contextLabel: String {
        let plan = contextPlan
        let used = Self.shortTokens(plan.usedTokens)
        let window = Self.shortTokens(plan.contextWindow)
        if plan.didCompact {
            return "\(used) / \(window) · сжато \(plan.compacted.count)"
        }
        return "\(used) / \(window)"
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
        composerHeight = 24
        attachments = []
        chat.send(text, attachments: files)
    }
}

struct HeaderBar: View {
    let palette: Palette
    let planMode: Bool
    @Environment(AppSettings.self) private var settings
    @Environment(ChatStore.self) private var chat

    var body: some View {
        HStack(spacing: 12) {
            Text("HARNES-S")
                .fontWeight(.semibold)
                .foregroundStyle(palette.text)

            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text("HARNES_S_DATA/workspace")
            }
            .foregroundStyle(palette.dim)

            Spacer(minLength: 12)

            if planMode {
                Text("plan")
                    .foregroundStyle(palette.reasoning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(palette.reasoningBackground)
                    .clipShape(Capsule())
            }

            Button {
                chat.setPlanMode(!planMode)
            } label: {
                Image(systemName: planMode ? "eye.slash" : "eye")
                    .font(.system(size: 11))
                    .frame(width: 22, height: 22)
                    .foregroundStyle(planMode ? palette.reasoning : palette.dim)
            }
            .buttonStyle(.borderless)
            .help(planMode ? "Выключить режим плана" : "Режим плана: только чтение")
            .accessibilityLabel("Режим плана")

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("Настройки (⌘,)")
            .accessibilityLabel("Настройки")
        }
        .font(AppFont.mono(11))
        .padding(.horizontal, 16)
        .frame(height: 38)
        .background(palette.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(palette.border)
                .frame(height: 1)
        }
    }
}

struct PlanBar: View {
    let todos: TodoStore
    let palette: Palette
    let fontSize: CGFloat

    @State private var expanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text("план · \(todos.items.filter { $0.status == "done" }.count)/\(todos.items.count)")
                    Spacer(minLength: 0)
                }
                .font(AppFont.mono(max(fontSize - 3, 9)))
                .foregroundStyle(palette.dim)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ForEach(todos.items) { item in
                    HStack(alignment: .top, spacing: 6) {
                        Text(mark(item.status))
                            .foregroundStyle(color(item.status))
                        Text(item.text)
                            .foregroundStyle(item.status == "done" ? palette.faint : palette.text)
                            .strikethrough(item.status == "done", color: palette.faint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(AppFont.mono(max(fontSize - 2, 10)))
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.panel.opacity(0.7))
        .overlay(alignment: .top) {
            Rectangle().fill(palette.border).frame(height: 1)
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
        case "done": palette.faint
        case "active", "in_progress": palette.accent
        case "cancelled": palette.number
        default: palette.dim
        }
    }
}
