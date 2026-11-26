import SwiftUI

/// R34: state of the ⌘K command palette. The actions themselves live in the view that
/// owns the environment; this only remembers whether the overlay is open, what the
/// person typed and which row is highlighted.
@MainActor
@Observable
final class CommandPaletteState {
    private(set) var isPresented = false
    var query = "" {
        didSet { if query != oldValue { selected = 0 } }
    }
    var selected = 0

    func toggle() {
        if isPresented { close() } else { open() }
    }

    func open() {
        isPresented = true
        query = ""
        selected = 0
    }

    func close() {
        isPresented = false
        query = ""
        selected = 0
    }
}

/// One row of the palette. `perform` is the existing menu action, not a new one.
struct PaletteAction: Identifiable {
    let id: String
    let title: String
    let systemImage: String
    var isEnabled = true
    let perform: () -> Void
}

/// R34: the overlay. Search field, filtered action list, ↑↓ to move, ↩ to run, Esc to
/// close. Width, material, radius and shadow follow `design/shots/03-palette-copper.png`.
struct CommandPaletteOverlay: View {
    @Bindable var palette: CommandPaletteState
    let actions: [PaletteAction]

    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    private var filtered: [PaletteAction] {
        let needle = palette.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return actions }
        return actions.filter { $0.title.localizedCaseInsensitiveContains(needle) }
    }

    private var selectionIndex: Int {
        min(max(palette.selected, 0), max(filtered.count - 1, 0))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.black.opacity(0.18))
                .ignoresSafeArea()
                .onTapGesture { palette.close() }

            VStack(spacing: Spacing.zero) {
                HStack(spacing: Spacing.small) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.labelTertiary)
                    TextField("Действие или команда", text: $palette.query)
                        .textFieldStyle(.plain)
                        .font(AppFont.ui(FontSize.panelField))
                        .focused($focused)
                        .onSubmit { run(filtered[safe: selectionIndex]) }
                        .onKeyPress(.downArrow) {
                            move(1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            move(-1)
                            return .handled
                        }
                }
                .padding(.horizontal, Spacing.medium)
                .padding(.vertical, Spacing.medium)

                Rectangle()
                    .fill(theme.separator)
                    .frame(height: Spacing.hairline)

                if filtered.isEmpty {
                    Text("Ничего не найдено")
                        .font(.caption)
                        .foregroundStyle(theme.labelTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.medium)
                } else {
                    VStack(spacing: Spacing.offGrid2) {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { index, action in
                            row(action, isSelected: index == selectionIndex)
                        }
                    }
                    .padding(Spacing.tight)
                }
            }
            .frame(width: Spacing.offGrid32 * 15)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.panel))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.panel)
                    .stroke(theme.separator, lineWidth: Spacing.hairline)
            )
            .shadow(color: .black.opacity(0.28), radius: Spacing.section, y: Spacing.medium)
            .padding(.top, Spacing.page)
        }
        .onAppear { focused = true }
        .onExitCommand { palette.close() }
        .transition(.opacity)
    }

    private func row(_ action: PaletteAction, isSelected: Bool) -> some View {
        Button {
            run(action)
        } label: {
            HStack(spacing: Spacing.small) {
                Image(systemName: action.systemImage)
                    .frame(width: Spacing.offGrid20, alignment: .center)
                    .foregroundStyle(isSelected ? theme.accent : theme.labelSecondary)
                Text(action.title)
                    .foregroundStyle(theme.labelPrimary)
                Spacer(minLength: Spacing.zero)
                if isSelected {
                    Text("↩")
                        .foregroundStyle(theme.labelTertiary)
                }
            }
            .font(AppFont.ui(FontSize.transcriptDefault))
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.offGrid6)
            .background(
                isSelected ? theme.accent.opacity(0.16) : Color.clear,
                in: RoundedRectangle(cornerRadius: Radius.small)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!action.isEnabled)
        .opacity(action.isEnabled ? 1 : 0.4)
        .onHover { hovering in
            if hovering, action.isEnabled { palette.selected = index(of: action) }
        }
        .accessibilityLabel(action.title)
    }

    private func index(of action: PaletteAction) -> Int {
        filtered.firstIndex(where: { $0.id == action.id }) ?? 0
    }

    private func move(_ delta: Int) {
        guard !filtered.isEmpty else { return }
        let count = filtered.count
        palette.selected = (selectionIndex + delta + count) % count
    }

    private func run(_ action: PaletteAction?) {
        guard let action, action.isEnabled else { return }
        palette.close()
        action.perform()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
