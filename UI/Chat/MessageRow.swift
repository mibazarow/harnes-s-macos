import AppKit
import SwiftUI

struct MessageRow: View, Equatable {
    let message: ChatMessage
    let palette: Palette
    let fontSize: CGFloat
    let showTimestamp: Bool

    /// Rows that did not change must not re-render while another row streams: with a
    /// plain stack this is what keeps a long transcript from re-parsing every message
    /// on every token.
    nonisolated static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
            && lhs.palette == rhs.palette
            && lhs.fontSize == rhs.fontSize
            && lhs.showTimestamp == rhs.showTimestamp
    }

    private var isUser: Bool { message.role == .user }

    var body: some View {
        BubbleContainer(isUser: isUser) {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(message.role.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(labelColor)

                if showTimestamp {
                    Text(message.date.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(palette.faint)
                }

                if message.state == .streaming {
                    Text("●")
                        .foregroundStyle(palette.accent)
                }

                switch message.state {
                case .queued:
                    StateBadge(
                        symbol: "clock",
                        text: "в очереди",
                        color: palette.reasoning,
                        fontSize: fontSize
                    )
                case .cancelled:
                    StateBadge(
                        symbol: "xmark",
                        text: "не отправлено",
                        color: palette.faint,
                        fontSize: fontSize
                    )
                case .streaming, .complete:
                    EmptyView()
                }

                Spacer(minLength: 0)
            }
            .font(AppFont.mono(max(fontSize - 2, 9)))

            if !message.tools.isEmpty {
                ToolTraceList(traces: message.tools, palette: palette, fontSize: fontSize)
            }

            if isUser {
                if !message.text.isEmpty {
                    Text(message.text)
                        .font(AppFont.mono(fontSize))
                        .foregroundStyle(palette.text)
                        .lineSpacing(AppFont.lineSpacing(for: fontSize))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !message.attachments.isEmpty {
                    AttachmentGrid(attachments: message.attachments, palette: palette, fontSize: fontSize)
                }
            } else {
                if let reasoning = message.reasoning, !reasoning.isEmpty {
                    ReasoningBlock(
                        text: reasoning,
                        palette: palette,
                        fontSize: fontSize
                    )
                }

                if !message.text.isEmpty {
                    MarkdownView(
                        text: message.text,
                        palette: palette,
                        fontSize: fontSize,
                        isStreaming: message.state == .streaming
                    )
                } else if message.state == .streaming,
                          message.tools.isEmpty,
                          (message.reasoning ?? "").isEmpty {
                    // Only before anything arrives. Once reasoning or a tool trace is on
                    // screen it already shows that work is happening, and a second
                    // "thinking" line under it is just noise.
                    Text("думает…")
                        .font(AppFont.mono(fontSize))
                        .foregroundStyle(palette.faint)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(bubbleBackground)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(isUser ? palette.accent.opacity(0.7) : palette.border)
                .frame(width: isUser ? 3 : 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contextMenu {
            Button("Копировать сообщение") { copyToPasteboard() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isUser ? "Сообщение пользователя" : "Ответ Харнеса")
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

    private var bubbleBackground: Color {
        isUser ? palette.userBackground : palette.panel
    }

    private var labelColor: Color {
        switch message.role {
        case .user: palette.accent
        case .assistant: palette.dim
        case .system: palette.faint
        }
    }
}

/// Small pill that explains why a message has no answer yet.
struct StateBadge: View {
    let symbol: String
    let text: String
    let color: Color
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: max(fontSize - 4, 8)))
            Text(text)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

struct AttachmentGrid: View {
    let attachments: [ChatAttachment]
    let palette: Palette
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { attachment in
                if let thumbnail = attachment.thumbnail,
                   let image = NSImage(data: thumbnail) {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path))
                    } label: {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 320, maxHeight: 220, alignment: .leading)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(palette.border, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Открыть \(attachment.name)")
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: symbol(for: attachment.kind))
                            .foregroundStyle(palette.dim)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(attachment.name)
                                .foregroundStyle(palette.text)
                            Text(attachment.kind == .folder ? attachment.path : attachment.summary)
                                .foregroundStyle(palette.faint)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .font(AppFont.mono(max(fontSize - 2, 9)))
                    .padding(8)
                    .background(palette.background.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
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
    let palette: Palette
    let fontSize: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(traces) { trace in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: symbol(for: trace))
                        .font(.system(size: 9))
                        .foregroundStyle(trace.isError ? palette.number : palette.faint)
                        .frame(width: 12)
                        .padding(.top, 1)

                    Text(trace.name)
                        .foregroundStyle(palette.dim)

                    Text(trace.summary)
                        .foregroundStyle(palette.faint)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Spacer(minLength: 0)

                    if trace.isRunning {
                        Text("…")
                            .foregroundStyle(palette.accent)
                    }
                }
                .font(AppFont.mono(max(fontSize - 3, 9)))

                if let path = trace.imagePath, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 420, maxHeight: 260, alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(palette.border, lineWidth: 1)
                        )
                        .padding(.leading, 18)
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.background.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
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

struct ReasoningBlock: View {
    let text: String
    let palette: Palette
    let fontSize: CGFloat

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    expanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                    Text(expanded ? "размышления" : "размышления · \(text.count) симв.")
                    Spacer(minLength: 0)
                }
                .font(AppFont.mono(max(fontSize - 2, 9)))
                .foregroundStyle(palette.reasoning)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Свернуть размышления" : "Показать размышления")

            if expanded {
                Text(text)
                    .font(AppFont.mono(fontSize))
                    .foregroundStyle(palette.reasoning)
                    .lineSpacing(AppFont.lineSpacing(for: fontSize))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.reasoningBackground)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(palette.reasoning.opacity(0.45))
                            .frame(width: 2)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// Full-width message body with a small symmetric inset.
/// Nothing is laid out beyond the available width, so shrinking the window
/// wraps text instead of pushing it off-screen.
struct BubbleContainer<Content: View>: View {
    let isUser: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 15)
    }
}
