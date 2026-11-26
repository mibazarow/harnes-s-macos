import SwiftUI

/// R33: state of the in-transcript search (⌘F).
///
/// Matches are counted per occurrence, not per message: the counter says how many hits
/// the query has, and navigation steps through them in reading order. The message id
/// attached to each hit is the id the transcript actually renders, so scrolling always
/// lands on a visible row.
@MainActor
@Observable
final class TranscriptSearch {
    private(set) var isPresented = false
    var query = "" {
        didSet { if query != oldValue { recompute(resetIndex: true) } }
    }
    private(set) var matches: [UUID] = []
    private(set) var current = 0
    /// Bumped on every explicit step, so ⌘G scrolls even when there is only one hit
    /// and the index itself does not change.
    private(set) var scrollToken = 0
    private var messages: [ChatMessage] = []

    var hasMatches: Bool { !matches.isEmpty }
    var currentMessageID: UUID? {
        matches.indices.contains(current) ? matches[current] : nil
    }

    var status: String {
        if query.isEmpty { return "" }
        if matches.isEmpty { return "нет совпадений" }
        return "\(current + 1) из \(matches.count)"
    }

    func present() {
        isPresented = true
    }

    func close() {
        isPresented = false
        query = ""
        matches = []
        current = 0
    }

    /// Called by the transcript whenever the visible rows change. A live answer keeps
    /// the current hit instead of jumping back to the first one on every token.
    func update(_ messages: [ChatMessage]) {
        self.messages = messages
        recompute(resetIndex: false)
    }

    func next() {
        guard !matches.isEmpty else { return }
        current = (current + 1) % matches.count
        scrollToken &+= 1
    }

    func previous() {
        guard !matches.isEmpty else { return }
        current = (current - 1 + matches.count) % matches.count
        scrollToken &+= 1
    }

    private func recompute(resetIndex: Bool) {
        let previous = current
        matches = []
        let needle = query
        if !needle.isEmpty {
            for message in messages {
                for _ in 0..<Self.hits(in: message, query: needle) {
                    matches.append(message.id)
                }
            }
        }
        if resetIndex {
            current = 0
        } else {
            current = min(previous, max(matches.count - 1, 0))
        }
    }

    /// Message text, reasoning and tool results: everything the transcript shows.
    static func hits(in message: ChatMessage, query: String) -> Int {
        guard !query.isEmpty else { return 0 }
        var total = count(message.text, query)
        if let reasoning = message.reasoning {
            total += count(reasoning, query)
        }
        for trace in message.tools {
            total += count(trace.summary, query)
        }
        return total
    }

    static func count(_ text: String, _ query: String) -> Int {
        guard !text.isEmpty, !query.isEmpty else { return 0 }
        var total = 0
        var start = text.startIndex
        while let range = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: start..<text.endIndex
        ) {
            total += 1
            start = range.upperBound
            if start == text.endIndex { break }
        }
        return total
    }
}

/// Paints every case-insensitive occurrence of the query on top of the text.
enum SearchHighlight {
    static func attributed(_ text: String, query: String, color: Color) -> AttributedString {
        applying(AttributedString(text), source: text, query: query, color: color)
    }

    /// `source` is the plain string the attributed text was built from; indices convert
    /// one-to-one because no characters were added or removed.
    static func applying(
        _ attributed: AttributedString,
        source: String,
        query: String,
        color: Color
    ) -> AttributedString {
        guard !query.isEmpty, !source.isEmpty else { return attributed }
        var result = attributed
        var start = source.startIndex
        while let range = source.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: start..<source.endIndex
        ) {
            if let lower = AttributedString.Index(range.lowerBound, within: result),
               let upper = AttributedString.Index(range.upperBound, within: result) {
                result[lower..<upper].backgroundColor = color
            }
            start = range.upperBound
            if start == source.endIndex { break }
        }
        return result
    }
}

/// R33: the find bar itself. A floating strip over the transcript, not a layout row, so
/// opening it never moves the conversation under the pointer.
struct TranscriptSearchBar: View {
    @Bindable var search: TranscriptSearch
    @Environment(\.theme) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.labelTertiary)

            TextField("Поиск по чату", text: $search.query)
                .textFieldStyle(.plain)
                .font(AppFont.ui(FontSize.transcriptDefault))
                .focused($focused)
                .frame(width: Spacing.offGrid32 * 7)

            Text(search.status)
                .font(.caption)
                .foregroundStyle(theme.labelSecondary)
                .monospacedDigit()
                .frame(minWidth: Spacing.offGrid32 * 2, alignment: .trailing)

            Button { search.previous() } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(!search.hasMatches)
            .help("Предыдущее совпадение (⌘⇧G)")

            Button { search.next() } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(!search.hasMatches)
            .help("Следующее совпадение (⌘G)")

            Button { search.close() } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("Закрыть поиск (Esc)")
        }
        .foregroundStyle(theme.labelSecondary)
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.panel)
                .stroke(theme.separator, lineWidth: Spacing.hairline)
        )
        .shadow(color: .black.opacity(0.18), radius: Spacing.medium, y: Spacing.offGrid3)
        .onAppear { focused = true }
        .onExitCommand { search.close() }
    }
}
