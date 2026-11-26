import AppKit
import SwiftUI

/// Code block: a raised plate, code face, copy button on hover.
///
/// The text scrolls horizontally inside the block, so a long line never stretches the
/// message column and never wraps into something that looks like broken code.
struct CodeBlockView: View {
    let code: String
    let language: String?
    let fontSize: CGFloat

    @Environment(\.theme) private var theme
    @State private var copied = false
    @State private var hovering = false
    @State private var resetTask: Task<Void, Never>?

    private var resolvedLanguage: CodeLanguage {
        CodeLanguage.detect(language)
    }

    private var showsButton: Bool {
        hovering || copied
    }

    private var codeSize: CGFloat {
        max(fontSize + FontSize.codeOffset, FontSize.minReadable)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(highlighted)
                .font(AppFont.mono(codeSize))
                .lineSpacing(AppFont.lineSpacing(for: codeSize))
                .selectableWhileIdle()
                .padding(.horizontal, Spacing.large)
                .padding(.vertical, Spacing.medium)
                .fixedSize(horizontal: true, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.codeBackground)
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel)
                .stroke(theme.separator, lineWidth: Spacing.hairline)
        )
        .overlay(alignment: .topTrailing) {
            Button {
                copy()
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .imageScale(.small)
                    .fontWeight(.medium)
                    .foregroundStyle(copied ? theme.accent : theme.labelSecondary)
                    .frame(width: Size.controlRegular, height: Size.controlRegular)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
            }
            .buttonStyle(.plain)
            .padding(Spacing.tight)
            .opacity(showsButton ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: showsButton)
            .help(copied ? "Скопировано" : "Скопировать код")
            .accessibilityLabel(copied ? "Скопировано" : "Скопировать код")
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.panel))
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    private var highlighted: AttributedString {
        HighlightCache.render(
            language: resolvedLanguage,
            palette: theme.syntax,
            themeID: theme.id,
            fontSize: codeSize,
            code: code
        )
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
