import SwiftUI

/// Floating list of slash-command hints above the composer. Arrow keys and Tab move and
/// pick, the mouse works too, and the hint line says so.
struct CommandPalette: View {
    let suggestions: [CommandSuggestion]
    let highlighted: Int
    let fontSize: CGFloat
    let onPick: (CommandSuggestion) -> Void

    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.zero) {
            // A plain stack, not a ScrollView: the list is capped at nine rows, so it
            // always fits.
            VStack(alignment: .leading, spacing: Spacing.zero) {
                ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                    row(item, selected: index == highlighted)
                }
            }

            Rectangle()
                .fill(theme.separator)
                .frame(height: Spacing.hairline)

            Text("↑↓ выбрать · Tab вставить · Esc скрыть")
                .font(.caption2)
                .foregroundStyle(theme.labelTertiary)
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.tight)
        }
        // A floating layer: material plus a hairline, no coloured border.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel)
                .stroke(theme.separator, lineWidth: Spacing.hairline)
        )
    }

    private func row(_ item: CommandSuggestion, selected: Bool) -> some View {
        Button {
            onPick(item)
        } label: {
            HStack(spacing: Spacing.medium) {
                Text(item.title)
                    .foregroundStyle(selected ? theme.labelPrimary : theme.labelSecondary)

                Text(item.detail)
                    .foregroundStyle(theme.labelTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: Spacing.zero)
            }
            .font(AppFont.ui(max(fontSize - 1, 10)))
            .padding(.horizontal, Spacing.medium)
            .frame(height: Size.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? theme.accent.opacity(0.14) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
