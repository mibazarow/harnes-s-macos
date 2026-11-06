import SwiftUI

struct TranscriptView: View {
    let palette: Palette
    let fontSize: CGFloat
    let showTimestamps: Bool

    @Environment(ChatStore.self) private var chat

    @State private var atBottom = true
    @State private var nearBottom = true
    /// True while the view should stay pinned to the newest message. Flipped off only
    /// when the user scrolls away by hand, never by the answer growing underneath.
    @State private var follow = true
    @State private var loadingOlder = false
    @State private var lastAutoScroll = Date.distantPast

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
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                return geometry.contentSize.height - offset - geometry.containerSize.height
            } action: { _, distance in
                nearBottom = distance <= 80
                atBottom = distance <= 120
            }
            .onScrollPhaseChange { _, phase in
                // Growth of the answer does not produce a scroll phase, so this is the
                // only place where the user's own scrolling can disable following.
                guard phase == .tracking || phase == .interacting || phase == .decelerating else { return }
                follow = nearBottom
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
                if !atBottom && !follow {
                    ScrollToBottomButton(palette: palette) {
                        follow = true
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
                // A message the user just sent always brings the view back down.
                if chat.messages.last?.role == .user {
                    follow = true
                }
                guard follow else { return }
                stick(proxy, animated: true)
            }
            .onChange(of: tailSignature) {
                guard follow else { return }
                stick(proxy)
            }
            .onAppear {
                follow = true
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    /// Coalesces streaming updates: scrolling on every token is janky, so the view
    /// is pinned at most ~25 times per second.
    private func stick(_ proxy: ScrollViewProxy, animated: Bool = false) {
        let now = Date()
        guard now.timeIntervalSince(lastAutoScroll) >= 0.04 else { return }
        lastAutoScroll = now
        if animated {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    /// Anything that changes the height of the newest message.
    private var tailSignature: Int {
        guard let last = chat.messages.last else { return 0 }
        return chat.messages.count
            &+ last.text.count
            &+ (last.reasoning?.count ?? 0)
            &+ last.tools.count
            &+ last.attachments.count
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