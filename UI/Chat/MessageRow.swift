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

                // R39: calls that ran before the answer read between the reasoning and
                // the text — that is when they happened. Calls made while the answer was
                // being written read below it.
                if !message.tools.isEmpty, message.toolsBeforeText {
                    traces
                }

                if !message.text.isEmpty {
                    AnswerText(
                        text: message.text,
                        fontSize: fontSize,
                        animate: animateReveal,
                        isStreaming: message.state == .streaming,
                        searchQuery: searchQuery
                    )
                }
            }

            if !isUser, !message.tools.isEmpty, !message.toolsBeforeText {
                traces
            }

            if let warning = message.warning, !warning.isEmpty {
                HStack(alignment: .top, spacing: Spacing.offGrid6) {
                    Image(systemName: "exclamationmark.triangle")
                        .imageScale(.small)
                    Text(warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A service line like the rest: same size, so a warning appearing does
                // not change the height of the bubble.
                .font(AppFont.status())
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

    private var traces: some View {
        ToolTraceList(
            traces: message.tools,
            isStreaming: message.state == .streaming,
            searchQuery: searchQuery
        )
    }

    /// Only states need a line now: the role name and the time are gone. A streaming
    /// bubble gets the line only while there is nothing else on screen — once reasoning
    /// or a trace is visible, that block carries its own spinner and a second one here
    /// would be two indicators for one process (R41).
    private var showsStateLine: Bool {
        switch message.state {
        case .streaming: showsThinkingLabel
        case .queued, .cancelled: true
        case .complete: false
        }
    }

    /// The streaming indicator and the `в очереди` / `не отправлено` badges. No role
    /// name, no timestamp: the bubble already says who wrote it.
    ///
    /// The spinner and the `думает…` label are one line, not two: the copper arc sits
    /// left, the word right after it, both at the status size. Nothing here follows the
    /// transcript size, so the line is the same height whatever the user chose.
    private var roleLine: some View {
        HStack(spacing: Spacing.offGrid6) {
            if showsThinkingLabel {
                StatusSpinner()
                Text("думает…")
                    .foregroundStyle(theme.labelTertiary)
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
        .font(AppFont.status())
        .foregroundStyle(theme.labelTertiary)
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityRole)
    }

    /// The word is only needed while there is nothing else on screen; once reasoning or
    /// a trace is visible, the spinner alone says the work is still going.
    private var showsThinkingLabel: Bool {
        message.state == .streaming
            && message.text.isEmpty
            && message.tools.isEmpty
            && (message.reasoning ?? "").isEmpty
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
        .font(AppFont.status())
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

/// R39: the tool calls of one message as a single block, not a wall of lines.
///
/// - the header says how many calls ran, how many failed and how long they took;
/// - while the answer is streaming the block is open, so work in progress is visible;
/// - once the message is complete it collapses to the header plus the first few calls;
/// - errors are never hidden: their lines stay visible even when collapsed;
/// - an active search opens the block, so matches are never behind a closed door;
/// - a single call without an error is one line, no header and no chevron.
struct ToolTraceList: View {
    let traces: [ToolTrace]
    var isStreaming: Bool = false
    var searchQuery: String = ""

    @Environment(\.theme) private var theme
    /// `nil` means "automatic": open while streaming, closed afterwards. A click pins
    /// the user's choice for the rest of the session.
    @State private var userChoice: Bool?

    /// How many calls the collapsed block shows before the rest hides behind the
    /// header. Errors are added on top of this and never cut.
    private let previewCount = 3

    private var expanded: Bool {
        if !searchQuery.isEmpty { return true }
        if let userChoice { return userChoice }
        return isStreaming
    }

    /// Nothing is hidden when every call already fits in the preview: a header would
    /// only add a line that says the obvious. One call, or three, are just rows.
    private var fitsWithoutHeader: Bool {
        traces.count <= previewCount
    }

    var body: some View {
        Group {
            if fitsWithoutHeader {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    ForEach(traces) { trace in
                        row(trace, compact: false)
                    }
                }
            } else {
                grouped
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var grouped: some View {
        VStack(alignment: .leading, spacing: Spacing.offGrid6) {
            Button {
                userChoice = !expanded
            } label: {
                HStack(spacing: Spacing.offGrid6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .imageScale(.small)
                        .foregroundStyle(theme.labelTertiary)

                    Text(header)
                        .foregroundStyle(theme.labelSecondary)

                    if traces.contains(where: { $0.isRunning }) {
                        StatusSpinner()
                    }

                    Spacer(minLength: Spacing.zero)
                }
                .font(AppFont.status())
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Свернуть вызовы инструментов" : "Показать вызовы инструментов")

            if expanded {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    ForEach(traces) { trace in
                        row(trace, compact: false)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    ForEach(collapsedTraces) { trace in
                        row(trace, compact: true)
                    }
                }
            }
        }
    }

    /// The first few calls plus every failure, so a broken call never hides behind the
    /// header even in the collapsed state.
    private var collapsedTraces: [ToolTrace] {
        let preview = traces.prefix(previewCount)
        let failures = traces.filter(\.isError)
        var seen = Set<UUID>()
        return (Array(preview) + failures).filter { seen.insert($0.id).inserted }
    }

    private var header: String {
        ToolTraceSummary(traces: traces).text
    }

    private func row(_ trace: ToolTrace, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hairline) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.offGrid6) {
                Image(systemName: symbol(for: trace))
                    .imageScale(.small)
                    .foregroundStyle(trace.isError ? theme.destructive : theme.labelTertiary)
                    .frame(width: Spacing.medium, alignment: .center)

                // Mono is for the tool name; the human line next to it is prose.
                // The strong copper is the readable one on light surfaces.
                Text(trace.name)
                    .font(AppFont.statusMono())
                    .foregroundStyle(theme.accentStrong)

                Text(SearchHighlight.attributed(
                    ToolTrace.summaryText(for: trace),
                    query: searchQuery,
                    color: theme.accent.opacity(0.28)
                ))
                    .foregroundStyle(trace.isError ? theme.destructive : theme.labelTertiary)
                    .lineLimit(compact ? 1 : 2)
                    .truncationMode(.middle)

                Spacer(minLength: Spacing.zero)

                if trace.isRunning {
                    StatusSpinner()
                }
            }
            .font(AppFont.status())

            if !compact, let path = trace.imagePath {
                LocalChatImage(path: path)
                    .frame(maxWidth: Spacing.offGrid32 * 13, maxHeight: Spacing.offGrid32 * 8, alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                    .padding(.leading, Spacing.offGrid20)
            }
        }
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
                        StatusSpinner()
                    }
                    Spacer(minLength: Spacing.zero)
                }
                // R41: the same size as every other service line, so opening the block
                // never changes the height of the answer above it.
                .font(AppFont.status())
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
