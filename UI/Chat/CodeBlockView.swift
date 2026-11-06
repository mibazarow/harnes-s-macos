import AppKit
import SwiftUI

struct CodeBlockView: View {
    let code: String
    let language: String?
    let palette: Palette
    let fontSize: CGFloat
    let lineSpacing: CGFloat

    @State private var copied = false
    @State private var resetTask: Task<Void, Never>?

    private var resolvedLanguage: CodeLanguage {
        CodeLanguage.detect(language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language?.lowercased() ?? "code")
                    .font(AppFont.mono(max(fontSize - 2, 9)))
                    .foregroundStyle(palette.faint)

                Spacer()

                Button {
                    copy()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(copied ? palette.accent : palette.faint)
                        .frame(width: 20, height: 18)
                }
                .buttonStyle(.borderless)
                .help(copied ? "Скопировано" : "Скопировать код")
                .accessibilityLabel(copied ? "Скопировано" : "Скопировать код")
            }
            .padding(.horizontal, 10)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Text(highlighted)
                .font(AppFont.mono(fontSize))
                .lineSpacing(lineSpacing)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .background(palette.codeBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(palette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
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