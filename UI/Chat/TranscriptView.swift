import SwiftUI

struct TranscriptView: View {
    let palette: Palette
    let fontSize: CGFloat
    let showTimestamps: Bool

    @Environment(ChatStore.self) private var chat

    @State private var atBottom = true
    @State private var loadingOlder = false

    private let bottomID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.isLoadingOlder || loadingOlder {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("загружаю историю…")
                                .font(AppFont.mono(max(fontSize - 2, 9)))
                                .foregroundStyle(palette.dim)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                    }

                    ForEach(chat.messages) { message in
                        MessageRow(
                            message: message,
                            palette: palette,
                            fontSize: fontSize,
                            showTimestamp: showTimestamps
                        )
                        .id(message.id)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .padding(.horizontal, 0)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(palette.background)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                let visible = geometry.containerSize.height
                return offset >= geometry.contentSize.height - visible - 120
            } action: { _, isAtBottom in
                atBottom = isAtBottom
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                let scrollable = geometry.contentSize.height > geometry.containerSize.height + 1
                return scrollable && offset < 160
            } action: { _, nearTop in
                guard nearTop, chat.hasMoreHistory, !loadingOlder else { return }
                Task { await loadOlder(proxy: proxy) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom {
                    ScrollToBottomButton(palette: palette) {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                    .padding(.trailing, 18)
                    .padding(.bottom, 14)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .onChange(of: chat.messages.count) {
                // Follow new messages only when already reading the end, or when the
                // user just sent something themselves.
                if atBottom || chat.messages.last?.role == .user {
                    withAnimation(.easeOut(duration: 0.16)) {
                        proxy.scrollTo(bottomID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: chat.messages.last?.text) {
                guard atBottom else { return }
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
            .onAppear {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private func loadOlder(proxy: ScrollViewProxy) async {
        guard chat.hasMoreHistory, !loadingOlder else { return }
        loadingOlder = true
        let anchor = chat.messages.first?.id
        await chat.loadOlder()
        loadingOlder = false
        if let anchor {
            proxy.scrollTo(anchor, anchor: .top)
        }
    }
}

private struct ScrollToBottomButton: View {
    let palette: Palette
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(palette.background)
                .frame(width: 30, height: 30)
                .background(hovering ? palette.reasoning : palette.accent)
                .overlay(
                    Circle()
                        .stroke(palette.reasoning.opacity(hovering ? 0.9 : 0.35), lineWidth: 1)
                )
                .clipShape(Circle())
                .shadow(color: palette.accent.opacity(0.35), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(.downArrow, modifiers: .command)
        .help("В конец чата (⌘↓)")
        .accessibilityLabel("Прокрутить в конец чата")
    }
}