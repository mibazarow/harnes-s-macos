import SwiftUI

struct TranscriptView: View {
    let fontSize: CGFloat
    let showTimestamps: Bool

    @Environment(ChatStore.self) private var chat
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var atBottom = true
    @State private var nearBottom = true
    /// True while the view should stay pinned to the newest message. Flipped off only
    /// when the user scrolls away by hand, never by the answer growing underneath.
    @State private var follow = true
    @State private var loadingOlder = false
    @State private var lastAutoScroll = Date.distantPast
    /// `displayed` used to be recomputed on every frame, and during a run the view
    /// redraws about sixteen times a second: every message in the window was grouped and
    /// copied that often on the main thread. Now it is rebuilt only when the transcript
    /// actually changed, keyed by `displaySignature`.
    @State private var displayedCache: [ChatMessage] = []

    private let bottomID = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // A plain stack, not LazyVStack: the lazy container drops all of its
                // children when the transcript is trimmed from the front or the tail
                // message grows, and the window goes blank until a manual scroll. The
                // view holds at most `ChatStore.transcriptCap` messages, so laying them
                // out eagerly is affordable — and unchanged rows are skipped by
                // `equatable()`.
                VStack(alignment: .leading, spacing: Spacing.offGrid10) {
                    if chat.isLoadingOlder || loadingOlder {
                        HStack(spacing: Spacing.small) {
                            ProgressView()
                                .controlSize(.small)
                            Text("загружаю историю…")
                                .font(.caption)
                                .foregroundStyle(theme.labelSecondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, Spacing.tight)
                    }

                    ForEach(displayed) { message in
                        MessageRow(
                            message: message,
                            fontSize: fontSize,
                            showTimestamp: showTimestamps,
                            animateReveal: chat.isStreaming || chat.revealID == message.id,
                            searchQuery: chat.search.query
                        )
                        .equatable()
                        .id(message.id)
                    }

                    // Pending messages sit at the very bottom, under the running
                    // answer, so they never drift up while the agent works.
                    ForEach(chat.queuedMessages) { message in
                        MessageRow(
                            message: message,
                            fontSize: fontSize,
                            showTimestamp: showTimestamps,
                            animateReveal: chat.isStreaming
                        )
                        .equatable()
                        .id(message.id)
                        .opacity(0.85)
                    }

                    Color.clear
                        .frame(height: Spacing.hairline)
                        .id(bottomID)
                }
                .padding(.horizontal, Spacing.zero)
                .padding(.vertical, Spacing.offGrid20)
                // The chat column never grows past 1100 pt, whatever the window does.
                .frame(maxWidth: Layout.chatContainer, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
                // Selection is applied per block instead of once for the whole stack:
                // the container-level modifier wrapped every run again, doubling the
                // platform text views and slowing layout on every width change.
            }
            .background(theme.contentBackground)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                return geometry.contentSize.height - offset - geometry.containerSize.height
            } action: { _, distance in
                nearBottom = distance <= Spacing.offGrid32 * 2 + Spacing.offGrid18
                atBottom = distance <= Spacing.offGrid32 * 4
            }
            .onScrollPhaseChange { _, phase in
                // Growth of the answer does not produce a scroll phase, so this is the
                // only place where the user's own scrolling can disable following.
                guard phase == .tracking || phase == .interacting || phase == .decelerating else { return }
                follow = nearBottom
            }
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height
            } action: { oldHeight, newHeight in
                // The typed reveal grows the bubble without touching `messages`, and the
                // markdown swap changes its height once more: the old triggers never saw
                // either, so the end of a long answer ended up below the fold.
                guard follow, newHeight > oldHeight else { return }
                stick(proxy)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let offset = geometry.contentOffset.y + geometry.contentInsets.top
                let scrollable = geometry.contentSize.height > geometry.containerSize.height + Spacing.hairline
                return scrollable && offset < Spacing.offGrid32 * 5
            } action: { _, nearTop in
                guard nearTop, chat.hasMoreHistory, !loadingOlder else { return }
                Task { await loadOlder(proxy: proxy) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !atBottom && !follow {
                    ScrollToBottomButton {
                        follow = true
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                    .padding(.trailing, Spacing.offGrid18)
                    .padding(.bottom, Spacing.offGrid14)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            // R33: the find bar floats over the transcript; opening it moves nothing.
            .overlay(alignment: .top) {
                if chat.search.isPresented {
                    TranscriptSearchBar(search: chat.search)
                        .padding(.top, Spacing.small)
                }
            }
            .onChange(of: chat.search.query) {
                chat.search.update(displayed)
                scrollToMatch(proxy)
            }
            .onChange(of: chat.search.scrollToken) {
                scrollToMatch(proxy)
            }
            .onChange(of: chat.messages.count) {
                // A message the user just sent always brings the view back down.
                if chat.messages.last?.role == .user {
                    follow = true
                }
                guard follow else { return }
                stick(proxy, animated: true)
            }
            .onChange(of: chat.queuedMessages.count) {
                // A message sent mid-run is the newest thing on screen, so the view
                // follows it like any other new message.
                follow = true
                stick(proxy, animated: true)
            }
            .onChange(of: tailSignature) {
                guard follow else { return }
                stick(proxy)
            }
            .onChange(of: displaySignature) {
                refreshDisplay()
            }
            .onAppear {
                follow = true
                refreshDisplay()
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
        if animated && !reduceMotion {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomID, anchor: .bottom)
        }
    }

    /// Messages as the transcript shows them: runs of tool-only steps collapsed into
    /// one bubble. Storage and the model's replay keep every step separate.
    private var displayed: [ChatMessage] {
        displayedCache
    }

    /// Compare values, not text lengths: tool completion and same-length edits matter.
    private var displaySignature: [ChatMessage] {
        chat.messages
    }

    private func refreshDisplay() {
        displayedCache = ChatMessage.groupedForDisplay(chat.messages).filter { !$0.isPruneNotice }
        chat.search.update(displayedCache)
    }

    /// R33: bring the current hit into view and stop following the tail, otherwise the
    /// next streaming chunk would pull the view straight back down.
    private func scrollToMatch(_ proxy: ScrollViewProxy) {
        guard let id = chat.search.currentMessageID else { return }
        follow = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }

    /// Anything that changes the height of the newest message.
    private var tailSignature: Int {
        let queued = chat.queuedMessages.count
        guard let last = chat.messages.last else { return queued }
        return chat.messages.count
            &+ queued
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
    let action: () -> Void

    @Environment(\.theme) private var theme
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .imageScale(.small)
                .fontWeight(.bold)
                .foregroundStyle(theme.onAccent)
                .frame(width: Size.controlRegular + Spacing.offGrid6, height: Size.controlRegular + Spacing.offGrid6)
                .background(hovering ? theme.accent.opacity(0.85) : theme.accent)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(.downArrow, modifiers: .command)
        .help("В конец чата (⌘↓)")
        .accessibilityLabel("Прокрутить в конец чата")
    }
}
