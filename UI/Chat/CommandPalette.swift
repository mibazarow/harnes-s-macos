import SwiftUI

/// Floating list above the composer. Arrow keys and Tab move and pick, the mouse works
/// too, and the hint line says so.
struct CommandPalette: View {
    let suggestions: [CommandSuggestion]
    let highlighted: Int
    let palette: Palette
    let fontSize: CGFloat
    let onPick: (CommandSuggestion) -> Void

    private var mono: Font { AppFont.mono(max(fontSize - 1, 10)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // A plain stack, not a ScrollView: the list is capped at nine rows, so it
            // always fits, and a scroll view here costs a gesture and renders worse.
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                    row(item, selected: index == highlighted)
                }
            }

            Rectangle()
                .fill(palette.border)
                .frame(height: 1)

            Text("↑↓ выбрать · Tab вставить · Esc скрыть")
                .font(AppFont.mono(max(fontSize - 3, 9)))
                .foregroundStyle(palette.faint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
        }
        .background(palette.background)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(palette.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func row(_ item: CommandSuggestion, selected: Bool) -> some View {
        Button {
            onPick(item)
        } label: {
            HStack(spacing: 10) {
                Text(item.title)
                    .foregroundStyle(selected ? palette.accent : palette.text)

                Text(item.detail)
                    .foregroundStyle(palette.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .font(mono)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? palette.accent.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
