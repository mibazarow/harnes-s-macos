import AppKit
import SwiftUI

struct MessageRow: View, Equatable {
    let message: ChatMessage
    let fontSize: CGFloat
    let showTimestamp: Bool
    /// New answers receive a brief opacity transition; history appears immediately.
    var animateReveal: Bool = false
    /// R33: the active find query; matching runs are tinted in every text surface.
    var searchQuery: String = ""

    @Environment(\.theme) private var theme
    /// Measured width of the transcript content, before the row's side padding. The
    /// bubble limits in `Bubble` are fractions of this width.
    @State private var containerWidth: CGFloat = 0

    /// Rows that did not change must not re-render while another row streams: with a
    /// plain stack this is what keeps a long transcript from re-parsing every message
    /// on every token.
    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.fontSize == rhs.fontSize
            && lhs.showTimestamp == rhs.showTimestamp
            && lhs.animateReveal == rhs.animateReveal
            && lhs.searchQuery == rhs.searchQuery
    }

    private var isUser: Bool { message.role == .user }

    var body: some View {
        // Both roles sit in bubbles: the user's words on a warm plate on the right, the
        // answer on a white plate on the left. The role line is gone — position and
        // shade already say who wrote what.
        HStack(spacing: Spacing.zero) {
            if isUser {
                Spacer(minLength: Spacing.zero)
            }

            bubble

            if !isUser {
                Spacer(minLength: Spacing.zero)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        // Measured before the column padding: the bubble limits are fractions of the
        // content box, exactly as `calc(100% - 50px)` and `86%` in the mockup.
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            containerWidth = width
        }
        // The 760 pt message column with 24 pt of air on each side, as in the mockup.
        .padding(.horizontal, Spacing.section)
        .frame(maxWidth: Layout.textColumn)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var bubble: some View {
        content
            .padding(.vertical, Bubble.verticalPadding)
            .padding(.horizontal, Bubble.horizontalPadding)
            // The answer is a block that fills its column; the user bubble hugs its
            // text and only stops at 86% of the container.
            .frame(maxWidth: isUser ? nil : .infinity, alignment: .leading)
            .background(bubbleBackground, in: bubbleShape)
            .overlay(bubbleShape.stroke(bubbleBorder, lineWidth: Spacing.hairline))
            .frame(
                maxWidth: containerWidth > 0
                    ? Bubble.maxWidth(container: containerWidth, isUser: isUser)
                    : nil,
                alignment: isUser ? .trailing : .leading
            )
    }

    private var bubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: Bubble.radius,
            bottomLeadingRadius: isUser ? Bubble.radius : Bubble.tailRadius,
            bottomTrailingRadius: isUser ? Bubble.tailRadius : Bubble.radius,
            topTrailingRadius: Bubble.radius
        )
    }

    private var bubbleBackground: Color {
        isUser ? theme.userBubble : theme.assistantBubble
    }

    private var bubbleBorder: Color {
        isUser ? theme.userBubbleBorder : theme.assistantBubbleBorder
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if showsStateLine {
                roleLine
            }

            if !message.tools.isEmpty {
                ToolTraceList(traces: message.tools, fontSize: fontSize, searchQuery: searchQuery)
            }

            if isUser {
                if !message.text.isEmpty {
                    Text(SearchHighlight.attributed(
                        message.text,
                        query: searchQuery,
                        color: theme.accent.opacity(0.28)
                    ))
                        .font(AppFont.ui(fontSize))
                        .foregroundStyle(theme.labelPrimary)
                        .lineSpacing(AppFont.lineSpacing(for: fontSize))
                        .selectableWhileIdle()
                        .fixedSize(horizontal: false, vertical: true)
                        // No width cap of its own: the user bubble hugs the text and
                        // stops at 86% of the column, as in the mockup.
                }
                if !message.attachments.isEmpty {
                    AttachmentGrid(attachments: message.attachments, fontSize: fontSize)
                }
            } else {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningBlock(
                        text: reasoning,
                        fontSize: fontSize,
                        isStreaming: message.state == .streaming,
                        searchQuery: searchQuery
                    )
                }

                if !message.text.isEmpty {
                    AnswerText(
                        text: message.text,
                        fontSize: fontSize,
                        animate: animateReveal,
                        isStreaming: message.state == .streaming,
                        searchQuery: searchQuery
                    )
                } else if message.state == .streaming,
                          message.tools.isEmpty,
                          (message.reasoning ?? "").isEmpty {
                    // Only before anything arrives. Once reasoning or a tool trace is on
                    // screen it already shows that work is happening, and a second
                    // "thinking" line under it is just noise.
                    Text("думает…")
                        .font(AppFont.ui(fontSize))
                        .foregroundStyle(theme.labelTertiary)
                }
            }

            if let warning = message.warning, !warning.isEmpty {
                HStack(alignment: .top, spacing: Spacing.offGrid6) {
                    Image(systemName: "exclamationmark.triangle")
                        .imageScale(.small)
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.caption)
                .foregroundStyle(theme.warning)
                .padding(.top, Spacing.offGrid2)
            }
        }
        .contextMenu {
            Button("Копировать сообщение", systemImage: "doc.on.doc") { copyToPasteboard() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isUser ? "Сообщение пользователя" : "Ответ Харнеса")
    }

    /// Only states need a line now: the role name and the time are gone. When a
    /// message is complete there is nothing to draw, so the row does not reserve an
    /// empty gap above the bubble.
    private var showsStateLine: Bool {
        switch message.state {
        case .streaming, .queued, .cancelled: true
        case .complete: false
        }
    }

    /// The streaming indicator and the `в очереди` / `не отправлено` badges. No role
    /// name, no timestamp: the bubble already says who wrote it.
    private var roleLine: some View {
        HStack(spacing: Spacing.offGrid6) {
            if message.state == .streaming {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.6)
                    .frame(width: Spacing.medium, height: Spacing.medium)
            }

            switch message.state {
            case .queued:
                StateBadge(symbol: "clock", text: "в очереди", tone: .neutral)
            case .cancelled:
                StateBadge(symbol: "xmark", text: "не отправлено", tone: .neutral)
            case .streaming, .complete:
                EmptyView()
            }

            Spacer(minLength: Spacing.zero)
        }
        .font(.caption2)
        .foregroundStyle(theme.labelTertiary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRole)
    }

    private var accessibilityRole: String {
        switch message.role {
        case .user: "Пользователь"
        case .assistant: "Ассистент"
        case .system: "Система"
        }
    }

    /// Whole-message copy for cases where dragging across several paragraphs is awkward.
    /// Selection inside the transcript still works for arbitrary pieces.
    private func copyToPasteboard() {
        var parts: [String] = []
        if let reasoning = message.reasoning, !reasoning.isEmpty {
            parts.append(reasoning)
        }
        if !message.text.isEmpty {
            parts.append(message.text)
        }
        guard !parts.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(parts.joined(separator: "\n\n"), forType: .string)
    }
}

/// Small pill that explains why a message has no answer yet. Icon plus text, never
/// colour alone.
struct StateBadge: View {
    enum Tone {
        case neutral
        case warning
    }

    let symbol: String
    let text: String
    var tone: Tone = .neutral

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: Spacing.tight) {
            Image(systemName: symbol)
                .imageScale(.small)
            Text(text)
        }
        .font(.caption2)
        .foregroundStyle(tone == .warning ? theme.warning : theme.labelSecondary)
        .padding(.horizontal, Spacing.offGrid6)
        .padding(.vertical, Spacing.offGrid2)
        .background(theme.labelQuaternary.opacity(0.15), in: Capsule())
    }
}

struct AttachmentGrid: View {
    let attachments: [ChatAttachment]
    let fontSize: CGFloat

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            ForEach(attachments) { attachment in
                if let thumbnail = attachment.thumbnail,
                   let image = NSImage(data: thumbnail) {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path))
                    } label: {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: Spacing.offGrid32 * 10, maxHeight: Spacing.offGrid20 * 11, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    }
                    .buttonStyle(.plain)
                    .help("Открыть \(attachment.name)")
                } else {
                    HStack(spacing: Spacing.small) {
                        Image(systemName: symbol(for: attachment.kind))
                            .foregroundStyle(theme.labelSecondary)
                        VStack(alignment: .leading, spacing: Spacing.hairline) {
                            Text(attachment.name)
                                .foregroundStyle(theme.labelPrimary)
                            Text(attachment.kind == .folder ? attachment.path : attachment.summary)
                                .foregroundStyle(theme.labelTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(.caption)
                    .padding(Spacing.small)
                    .background(theme.controlBackground, in: RoundedRectangle(cornerRadius: Radius.control))
                }
            }
        }
    }
}

private func symbol(for kind: ChatAttachment.Kind) -> String {
    switch kind {
    case .folder: "folder"
    case .text: "doc.text"
    case .image: "photo"
    case .other: "doc"
    }
}

struct ToolTraceList: View {
    let traces: [ToolTrace]
    let fontSize: CGFloat
    var searchQuery: String = ""

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            ForEach(traces) { trace in
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.offGrid6) {
                        Image(systemName: symbol(for: trace))
                            .imageScale(.small)
                            .foregroundStyle(trace.isError ? theme.destructive : theme.labelTertiary)
                            .frame(width: Spacing.medium, alignment: .center)

                        // Mono is for the tool name; the human line next to it is prose.
                        // The strong copper is the readable one on light surfaces.
                        Text(trace.name)
                            .font(AppFont.mono(max(fontSize - 2, FontSize.minReadable)))
                            .foregroundStyle(theme.accentStrong)

                        Text(SearchHighlight.attributed(
                            ToolTrace.summaryText(for: trace),
                            query: searchQuery,
                            color: theme.accent.opacity(0.28)
                        ))
                            .foregroundStyle(theme.labelTertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)

                        Spacer(minLength: Spacing.zero)

                        if trace.isRunning {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.6)
                                .frame(width: Spacing.medium, height: Spacing.medium)
                        }
                    }
                    .font(.caption)

                    if let path = trace.imagePath {
                        LocalChatImage(path: path)
                            .frame(maxWidth: Spacing.offGrid32 * 13, maxHeight: Spacing.offGrid32 * 8, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                            .padding(.leading, Spacing.offGrid20)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func symbol(for trace: ToolTrace) -> String {
        if trace.isError { return "exclamationmark.triangle" }
        if trace.isRunning { return "circle.dotted" }
        switch trace.name {
        case "browser", "webfetch", "websearch": return "globe"
        case "screenshot", "ocr": return "eye"
        case "bash": return "terminal"
        case "fs_read", "fs_write", "edit_file", "fs_list": return "doc"
        case "memory_add", "memory_search": return "brain"
        case "secret_get", "secret_save", "secret_search": return "key"
        default: return "wrench"
        }
    }
}

/// File reads belong to the view lifetime, not each streaming/layout update.
struct LocalChatImage: View {
    let path: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "photo")
                    .accessibilityLabel("Изображение недоступно или загружается")
            }
        }
        .task(id: path) {
            image = nil
            let filePath = path
            let loader = Task.detached(priority: .utility) {
                try? Data(contentsOf: URL(fileURLWithPath: filePath))
            }
            let data = await withTaskCancellationHandler {
                await loader.value
            } onCancel: {
                loader.cancel()
            }
            guard !Task.isCancelled else { return }
            image = data.flatMap(NSImage.init(data:))
        }
    }
}

struct ReasoningBlock: View {
    let text: String
    let fontSize: CGFloat
    var isStreaming: Bool = false
    var searchQuery: String = ""

    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.offGrid6) {
            Button {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: Spacing.offGrid6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                    Text("размышления")
                    if isStreaming {
                        ProgressView()
                            .controlSize(.mini)
                            .scaleEffect(0.6)
                            .frame(width: Spacing.medium, height: Spacing.medium)
                    }
                    Spacer(minLength: Spacing.zero)
                }
                .font(.caption)
                .foregroundStyle(theme.labelSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Свернуть размышления" : "Показать размышления")

            if expanded {
                Text(SearchHighlight.attributed(
                    text,
                    query: searchQuery,
                    color: theme.accent.opacity(0.28)
                ))
                    .font(AppFont.ui(fontSize))
                    .foregroundStyle(theme.labelSecondary)
                    .lineSpacing(AppFont.lineSpacing(for: fontSize))
                    .selectableWhileIdle()
                    .padding(Spacing.medium)
                    .frame(maxWidth: Layout.textColumn, alignment: .leading)
                    .background(theme.reasoningBackground, in: RoundedRectangle(cornerRadius: Radius.control))
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Render the final layout immediately; appearance never delays access to the answer.
struct AnswerText: View {
    let text: String
    let fontSize: CGFloat
    var animate: Bool = false
    var isStreaming: Bool = false
    var searchQuery: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        MarkdownView(
            text: text,
            fontSize: fontSize,
            isStreaming: isStreaming,
            highlight: searchQuery
        )
            .opacity(appeared || !animate || reduceMotion ? 1 : 0.85)
            .onAppear {
                withAnimation(reduceMotion || !animate ? nil : .easeOut(duration: 0.16)) {
                    appeared = true
                }
            }
    }
}
