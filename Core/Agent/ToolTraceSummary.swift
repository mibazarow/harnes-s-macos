import Foundation

/// R39: the one-line header of a group of tool calls: `12 вызовов · 3 ошибки · 18 с`.
///
/// Pure data, so the wording and the plural forms are pinned by tests instead of being
/// buried in a view.
struct ToolTraceSummary: Equatable, Sendable {
    let calls: Int
    let errors: Int
    let seconds: TimeInterval

    init(traces: [ToolTrace]) {
        calls = traces.count
        errors = traces.filter(\.isError).count
        seconds = traces.compactMap(\.duration).reduce(0, +)
    }

    init(calls: Int, errors: Int = 0, seconds: TimeInterval = 0) {
        self.calls = calls
        self.errors = errors
        self.seconds = seconds
    }

    var text: String {
        var parts = [Self.callsText(calls)]
        if errors > 0 { parts.append(Self.errorsText(errors)) }
        if seconds > 0 { parts.append(Self.durationText(seconds)) }
        return parts.joined(separator: " · ")
    }

    static func callsText(_ count: Int) -> String {
        "\(count) \(plural(count, one: "вызов", few: "вызова", many: "вызовов"))"
    }

    static func errorsText(_ count: Int) -> String {
        "\(count) \(plural(count, one: "ошибка", few: "ошибки", many: "ошибок"))"
    }

    /// Under ten seconds one decimal is useful ("0,4 с"); above it the tenths are noise.
    static func durationText(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "" }
        // 9.96 rounds to 10, so the cutoff is on the rounded value, not the raw one.
        if seconds < 9.95 {
            let tenths = String(format: "%.1f", seconds).replacingOccurrences(of: ".", with: ",")
            return "\(tenths) с"
        }
        return "\(Int(seconds.rounded())) с"
    }

    private static func plural(_ count: Int, one: String, few: String, many: String) -> String {
        let tail = abs(count) % 100
        let last = tail % 10
        if tail >= 11, tail <= 14 { return many }
        if last == 1 { return one }
        if (2...4).contains(last) { return few }
        return many
    }
}
