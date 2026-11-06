import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Binding var text: String
    @Binding var height: CGFloat
    @Binding var attachments: [ChatAttachment]
    let palette: Palette
    let fontSize: CGFloat
    let isStreaming: Bool
    let queuedCount: Int
    let providerLabel: String
    let contextLabel: String
    let contextWarning: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @State private var isTargeted = false

    private var mono: Font { AppFont.mono(fontSize) }

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(palette.border)
                .frame(height: 1)

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { attachment in
                            AttachmentChip(
                                attachment: attachment,
                                palette: palette,
                                fontSize: fontSize
                            ) {
                                attachments.removeAll { $0.id == attachment.id }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text("❯")
                        .font(mono)
                        .foregroundStyle(palette.accent)
                        .padding(.top, 5)

                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(isTargeted ? "Отпусти файл" : "Напиши…")
                                .font(mono)
                                .foregroundStyle(isTargeted ? palette.accent : palette.faint)
                                .padding(.top, 5)
                                .allowsHitTesting(false)
                        }

                        ComposerTextView(
                            text: $text,
                            height: $height,
                            fontSize: fontSize,
                            textColor: palette.text.nsColor,
                            insertionColor: palette.accent.nsColor,
                            onSend: onSend
                        )
                        .frame(height: height)
                    }

                    Button(action: addFiles) {
                        Image(systemName: "paperclip")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.dim)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .help("Прикрепить файл")
                    .accessibilityLabel("Прикрепить файл")

                    Button(action: addFolder) {
                        Image(systemName: "folder")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(palette.dim)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .help("Выбрать папку для работы")
                    .accessibilityLabel("Выбрать папку")

                    if isStreaming {
                        // One control, two meanings: the ring says "working", the square
                        // says "you can still stop this".
                        StopButton(palette: palette, action: onStop)
                    }

                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(palette.accent)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty)
                    .help(isStreaming ? "В очередь (Return)" : "Отправить (Return)")
                    .accessibilityLabel(isStreaming ? "Поставить в очередь" : "Отправить")
                }

                HStack(spacing: 8) {
                    Text("⏎ отправить · ⇧⏎ перенос · Esc стоп · / команды")
                        .foregroundStyle(palette.dim)

                    if queuedCount > 0 {
                        Text("· в очереди: \(queuedCount)")
                            .foregroundStyle(palette.reasoning)
                    }

                    Spacer(minLength: 8)

                    Text(providerLabel)
                        .foregroundStyle(palette.faint)
                        .lineLimit(1)

                    Text("·")
                        .foregroundStyle(palette.faint)

                    Text(contextLabel)
                        .foregroundStyle(contextWarning ? palette.reasoning : palette.faint)
                        .help(contextWarning
                              ? "История превышает порог окна: при отправке старые сообщения свернутся в саммари"
                              : "Заполнение окна контекста")
                }
                .font(AppFont.mono(max(fontSize - 3, 9)))
                .padding(.leading, 18)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 8)
        }
        .background(palette.panel)
        .overlay(alignment: .top) {
            if isTargeted {
                Rectangle()
                    .fill(palette.accent.opacity(0.12))
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
        }
        .onExitCommand(perform: onStop)
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

struct AttachmentChip: View {
    let attachment: ChatAttachment
    let palette: Palette
    let fontSize: CGFloat
    let onRemove: () -> Void

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
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: chipSymbol)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.dim)
                    .frame(width: 28, height: 28)
            }

            Text(attachment.name)
                .font(AppFont.mono(max(fontSize - 2, 9)))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .frame(maxWidth: 160, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(palette.dim)
            }
            .buttonStyle(.borderless)
            .help("Убрать")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(palette.background.opacity(0.8))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = AppFont.nsMono(fontSize)
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

        if textView.string != text {
            textView.string = text
        }

        textView.font = AppFont.nsMono(fontSize)
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

    override func keyDown(with event: NSEvent) {
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
    let palette: Palette
    let action: () -> Void

    @State private var spinning = false
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .stroke(palette.border, lineWidth: 2)

                Circle()
                    .trim(from: 0, to: 0.28)
                    .stroke(
                        palette.accent,
                        style: StrokeStyle(lineWidth: 2, lineCap: .round)
                    )
                    .rotationEffect(.degrees(spinning ? 360 : 0))
                    .animation(
                        .linear(duration: 1.1).repeatForever(autoreverses: false),
                        value: spinning
                    )

                RoundedRectangle(cornerRadius: 2)
                    .fill(hovering ? palette.reasoning : palette.accent)
                    .frame(width: 9, height: 9)
            }
            .frame(width: 26, height: 26)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .onAppear { spinning = true }
        .help("Идёт работа · нажми, чтобы остановить (Esc)")
        .accessibilityLabel("Остановить ответ")
    }
}
