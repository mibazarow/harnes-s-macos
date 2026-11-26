import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var attachments: [ChatAttachment]
    let fontSize: CGFloat
    let isStreaming: Bool
    let queuedCount: Int
    let providerLabel: String
    let contextLabel: String
    let contextWarning: Bool
    let modelLabel: String?
    let modelWarning: Bool
    let spent: Double
    let onSend: () -> Void
    let onStop: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isTargeted = false
    @State private var highlightedCommand = 0
    @State private var paletteHidden = false

    private var ui: Font { AppFont.ui(fontSize) }

    private var suggestions: [CommandSuggestion] {
        paletteHidden ? [] : CommandCatalog.suggestions(for: text)
    }

    var body: some View {
        VStack(spacing: Spacing.zero) {
            Rectangle()
                .fill(theme.separator)
                .frame(height: Spacing.hairline)

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.small) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(attachment: attachment, fontSize: fontSize) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                    .padding(.horizontal, Spacing.large)
                    .padding(.top, Spacing.small)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                if !suggestions.isEmpty {
                    CommandPalette(
                        suggestions: suggestions,
                        highlighted: min(highlightedCommand, suggestions.count - 1),
                        fontSize: fontSize,
                        onPick: accept
                    )
                    .padding(.bottom, Spacing.offGrid2)
                }

                HStack(alignment: .top, spacing: Spacing.small) {
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(theme.labelTertiary)
                        .padding(.top, Spacing.offGrid5)

                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(isTargeted ? "Отпусти файл" : "Напиши…")
                                .font(ui)
                                .foregroundStyle(isTargeted ? theme.accent : theme.labelQuaternary)
                                .padding(.top, Spacing.offGrid5)
                                .allowsHitTesting(false)
                        }

                        ComposerTextView(
                            text: $text,
                            height: $height,
                            fontSize: fontSize,
                            textColor: theme.labelPrimary.nsColor,
                            insertionColor: theme.accent.nsColor,
                            onSend: onSend,
                            keyHandler: handlePaletteKey
                        )
                        .frame(height: height)
                    }

                    Button(action: addFiles) {
                        Image(systemName: "paperclip")
                            .imageScale(.medium)
                            .foregroundStyle(theme.labelSecondary)
                            .frame(width: Size.controlRegular, height: Size.controlRegular)
                    }
                    .buttonStyle(.borderless)
                    .help("Прикрепить файл")
                    .accessibilityLabel("Прикрепить файл")

                    Button(action: addFolder) {
                        Image(systemName: "folder")
                            .imageScale(.medium)
                            .foregroundStyle(theme.labelSecondary)
                            .frame(width: Size.controlRegular, height: Size.controlRegular)
                    }
                    .buttonStyle(.borderless)
                    .help("Выбрать папку для работы")
                    .accessibilityLabel("Выбрать папку")

                    if isStreaming {
                        // One control, two meanings: the ring says "working", the square
                        // says "you can still stop this".
                        StopButton(action: onStop)
                    }

                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .imageScale(.medium)
                            .fontWeight(.semibold)
                            .foregroundStyle(canSend ? theme.onAccent : theme.labelQuaternary)
                            .frame(width: Size.controlRegular, height: Size.controlRegular)
                            .background(canSend ? theme.accent : theme.labelQuaternary.opacity(0.15), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .controlSize(.small)
                    .disabled(!canSend)
                    .help(isStreaming ? "В очередь (Return)" : "Отправить (Return)")
                    .accessibilityLabel(isStreaming ? "Поставить в очередь" : "Отправить")
                }

                HStack(spacing: Spacing.small) {
                    Text("⏎ отправить · ⇧⏎ перенос · Esc стоп · / команды")
                        .foregroundStyle(theme.labelTertiary)

                    if queuedCount > 0 {
                        Text("· в очереди: \(queuedCount)")
                            .foregroundStyle(theme.warning)
                    }

                    if spent > 0 {
                        Text("· $\(spent.formatted(.number.precision(.fractionLength(2))))")
                            .foregroundStyle(theme.labelTertiary)
                            .help("Потрачено по текущим ценам провайдера. Считается из usage каждого запроса.")
                    }

                    if let modelLabel {
                        Text("· \(modelLabel)")
                            .foregroundStyle(modelWarning ? theme.warning : theme.labelTertiary)
                            .help(modelWarning
                                  ? "Модель эмбеддингов не скачалась. Семантический поиск работает по ключевым словам; загрузка повторится при следующем запуске."
                                  : "Скачивается встроенная модель эмбеддингов. До конца загрузки поиск по памяти работает по ключевым словам.")
                    }

                    Spacer(minLength: Spacing.small)

                    // Meta pills: capsule, caption, secondary; warning keeps its icon so
                    // the state is not carried by colour alone.
                    Text(providerLabel)
                        .lineLimit(1)
                        .modifier(MetaPill())

                    HStack(spacing: Spacing.tight) {
                        if contextWarning {
                            Image(systemName: "exclamationmark.triangle")
                                .imageScale(.small)
                        }
                        Text(contextLabel)
                    }
                    .modifier(MetaPill(warning: contextWarning))
                    .help(contextWarning
                          ? "История превышает порог окна: при отправке старые сообщения свернутся в саммари"
                          : "Заполнение окна контекста")
                }
                .font(.caption2)
                .padding(.leading, Spacing.offGrid18)
            }
            .padding(.horizontal, Spacing.large)
            .padding(.top, Spacing.offGrid10)
            .padding(.bottom, Spacing.small)
        }
        // Content, not chrome: a solid plate with a hairline, not glass and not a capsule.
        .background(theme.controlBackground)
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel)
                .stroke(isTargeted ? theme.accent : theme.separator, lineWidth: Spacing.hairline)
        )
        .frame(maxWidth: Layout.chatContainer)
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.horizontal, Spacing.large)
        .padding(.bottom, Spacing.medium)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .onChange(of: text) {
            // Every edit re-opens the palette and resets the cursor: typing "m" after
            // "/" should start from the first match, not from the old position.
            paletteHidden = false
            highlightedCommand = 0
        }
        .onExitCommand(perform: onStop)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    /// Returns true when the key belonged to the palette and must not reach the text
    /// view: arrows, Tab, Enter and Escape while a suggestion is on screen.
    private func handlePaletteKey(_ event: NSEvent) -> Bool {
        let items = suggestions
        guard !items.isEmpty else { return false }

        switch event.keyCode {
        case 126: // up
            highlightedCommand = (highlightedCommand - 1 + items.count) % items.count
            return true
        case 125: // down
            highlightedCommand = (highlightedCommand + 1) % items.count
            return true
        case 48, 36, 76: // tab, return, keypad enter
            accept(items[min(highlightedCommand, items.count - 1)])
            return true
        case 53: // escape
            paletteHidden = true
            return true
        default:
            return false
        }
    }

    private func accept(_ suggestion: CommandSuggestion) {
        text = suggestion.insert
        highlightedCommand = 0
        paletteHidden = false
    }

    private func addFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.title = "Прикрепить файлы"
        if panel.runModal() == .OK {
            appendFiles(panel.urls)
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Выбрать папку"
        panel.title = "Папка для работы"
        if panel.runModal() == .OK, let url = panel.url {
            let folder = ChatAttachment(folder: url)
            if !attachments.contains(where: { $0.kind == .folder && $0.path == folder.path }) {
                attachments.append(folder)
            }
        }
    }

    /// Collects dropped URLs in a lock-protected box: `NSItemProvider` completions
    /// arrive on arbitrary queues, so a captured `var` would be a data race.
    private final class URLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL] = []

        func append(_ url: URL) {
            lock.lock(); urls.append(url); lock.unlock()
        }

        var all: [URL] {
            lock.lock(); defer { lock.unlock() }
            return urls
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let box = URLBox()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { box.append(url) }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            appendFiles(box.all)
        }
        return true
    }

    private func appendFiles(_ urls: [URL]) {
        let loaded = urls.compactMap(ChatAttachment.init(url:))
        attachments.append(contentsOf: loaded)
    }
}

/// Caption pill for provider and context. No border: the fill carries the grouping.
private struct MetaPill: ViewModifier {
    var warning = false

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .font(.caption2)
            .foregroundStyle(warning ? theme.warning : theme.labelSecondary)
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.offGrid2)
            .background(
                (warning ? theme.warning : theme.labelQuaternary).opacity(0.12),
                in: Capsule()
            )
    }
}

struct AttachmentChip: View {
    let attachment: ChatAttachment
    let fontSize: CGFloat
    let onRemove: () -> Void

    @Environment(\.theme) private var theme

    private var chipSymbol: String {
        switch attachment.kind {
        case .folder: "folder"
        case .text: "doc.text"
        case .image: "photo"
        case .other: "doc"
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            if let thumbnail = attachment.thumbnail, let image = NSImage(data: thumbnail) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: Size.row, height: Size.row)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small))
            } else {
                Image(systemName: chipSymbol)
                    .imageScale(.medium)
                    .foregroundStyle(theme.labelSecondary)
                    .frame(width: Size.row, height: Size.row)
            }

            Text(attachment.name)
                .font(.caption)
                .foregroundStyle(theme.labelPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: Spacing.offGrid32 * 5, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .imageScale(.small)
                    .fontWeight(.bold)
                    .foregroundStyle(theme.labelSecondary)
            }
            .buttonStyle(.borderless)
            .help("Убрать")
        }
        .padding(.horizontal, Spacing.small)
        .padding(.vertical, Spacing.offGrid5)
        .background(theme.controlBackground, in: RoundedRectangle(cornerRadius: Radius.control))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control)
                .stroke(theme.separator, lineWidth: Spacing.hairline)
        )
    }
}

private extension Color {
    var nsColor: NSColor {
        NSColor(self)
    }
}

struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let fontSize: CGFloat
    let textColor: NSColor
    let insertionColor: NSColor
    let onSend: () -> Void
    let keyHandler: ((NSEvent) -> Bool)?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = ComposerNSTextView()
        textView.onSend = onSend
        textView.keyHandler = keyHandler
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = AppFont.nsUI(fontSize)
        textView.textColor = textColor
        textView.insertionPointColor = insertionColor
        textView.textContainerInset = NSSize(width: 0, height: 5)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.string = text

        scrollView.documentView = textView
        context.coordinator.textView = textView

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ComposerNSTextView else { return }
        context.coordinator.parent = self
        textView.onSend = onSend
        textView.keyHandler = keyHandler

        if textView.string != text {
            textView.string = text
            // Text set from outside (a picked command) should leave the caret at the
            // end, otherwise the next keystroke lands at the start.
            textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }

        textView.font = AppFont.nsUI(fontSize)
        textView.textColor = textColor
        textView.insertionPointColor = insertionColor

        DispatchQueue.main.async {
            context.coordinator.recalculateHeight(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ComposerTextView
        weak var textView: NSTextView?

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recalculateHeight(textView)
        }

        func recalculateHeight(_ textView: NSTextView) {
            guard let layoutManager = textView.layoutManager,
                  let container = textView.textContainer else { return }
            layoutManager.ensureLayout(for: container)
            let used = layoutManager.usedRect(for: container).height
            let inset = textView.textContainerInset.height * 2
            let next = min(max(used + inset + 2, 24), 180)
            if abs(parent.height - next) > 0.5 {
                parent.height = next
            }
        }
    }
}

final class ComposerNSTextView: NSTextView {
    var onSend: (() -> Void)?
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true {
            return
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                onSend?()
            }
            return
        }
        super.keyDown(with: event)
    }
}

/// Stop control with a running indicator around it. The ring rotates continuously and
/// the centre stays a plain stop square, so the affordance never changes shape while
/// the agent works.
private struct StopButton: View {
    let action: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    /// The angle is a function of the clock, not a `repeatForever` state animation.
    /// That animation was restarted by every re-render of the composer during streaming
    /// — sixty times a second of re-evaluation meant the ring kept snapping back to zero
    /// and looked frozen at ~5 FPS. A timeline keeps rotating regardless of body updates.
    private static let period: TimeInterval = 1.1

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(theme.separator, lineWidth: Spacing.offGrid2)

                if reduceMotion {
                    // Reduce Motion: the ring stops spinning and stays a plain stop ring.
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(theme.destructive, style: StrokeStyle(lineWidth: Spacing.offGrid2, lineCap: .round))
                } else {
                    TimelineView(.animation) { context in
                        Circle()
                            .trim(from: 0, to: 0.28)
                            .stroke(
                                theme.destructive,
                                style: StrokeStyle(lineWidth: Spacing.offGrid2, lineCap: .round)
                            )
                            .rotationEffect(.degrees(Self.angle(at: context.date)))
                    }
                }

                RoundedRectangle(cornerRadius: Spacing.offGrid2)
                    .fill(hovering ? theme.destructive.opacity(0.8) : theme.destructive)
                    .frame(width: Spacing.offGrid10, height: Spacing.offGrid10)
            }
            .frame(width: Size.controlRegular, height: Size.controlRegular)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Идёт работа · нажми, чтобы остановить (Esc)")
        .accessibilityLabel("Остановить ответ")
    }

    private static func angle(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: period) / period
        return phase * 360
    }
}
