import AppKit
import SwiftUI

/// Code block. The reference UI has no header bar: the block is a plain raised plate,
/// and a small copy button fades in on hover in the top-right corner.
struct CodeBlockView: View {
    let code: String
    let language: String?
    let palette: Palette
    let fontSize: CGFloat

    @State private var copied = false
    @State private var hovering = false
    @State private var resetTask: Task<Void, Never>?

    private var resolvedLanguage: CodeLanguage {
        CodeLanguage.detect(language)
    }

    private var showsButton: Bool {
        hovering || copied
    }

    var body: some View {
        Text(highlighted)
            .font(AppFont.mono(fontSize))
            .lineSpacing(AppFont.lineSpacing(for: fontSize))
            .textSelection(.enabled)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(palette.codeBackground)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(palette.border, lineWidth: 1)
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    copy()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? palette.accent : palette.dim)
                        .frame(width: 24, height: 24)
                        .background(palette.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(palette.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(4)
                .opacity(showsButton ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: showsButton)
                .help(copied ? "Скопировано" : "Скопировать код")
                .accessibilityLabel(copied ? "Скопировано" : "Скопировать код")
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onHover { hovering = $0 }
            .accessibilityElement(children: .contain)
    }

    private var highlighted: AttributedString {
        SyntaxHighlighter(
            language: resolvedLanguage,
            palette: palette,
            fontSize: fontSize
        ).highlight(code)
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)

        copied = true
        resetTask?.cancel()
        resetTask = Task {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            copied = false
        }
    }
}
