import Foundation

/// R33.3: two records in the same area that cannot both be true are shown as such.
///
/// Nothing is fixed automatically — the user decides which one is current. The point is
/// to show the contradiction in `memory_list` before it reaches the prompt and gets
/// repeated as fact.
enum MemoryContradiction {
    /// Word pairs that flip the meaning. Matched as whole tokens, so "нет" does not fire
    /// inside "нетерпеливый".
    static let opposites: [(String, String)] = [
        ("до", "после"),
        ("есть", "нет"),
        ("можно", "нельзя"),
        ("включён", "выключен"),
        ("включен", "выключен"),
        ("разрешено", "запрещено")
    ]

    private static let dateRegex = try! NSRegularExpression(
        pattern: "\\b\\d{2}\\.\\d{2}\\.\\d{4}\\b"
    )

    static func dates(in text: String) -> Set<String> {
        let range = NSRange(text.startIndex..., in: text)
        return Set(dateRegex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }

    /// id -> the record it contradicts. Both sides are marked, so the list is symmetric.
    static func marks(_ items: [MemoryItem]) -> [Int64: Int64] {
        var result: [Int64: Int64] = [:]
        let byArea = Dictionary(grouping: items, by: \.area)

        for group in byArea.values where group.count > 1 {
            for left in group.indices {
                for right in group.index(after: left)..<group.endIndex {
                    let a = group[left]
                    let b = group[right]
                    guard conflicts(a, b) else { continue }
                    if result[a.id] == nil { result[a.id] = b.id }
                    if result[b.id] == nil { result[b.id] = a.id }
                }
            }
        }
        return result
    }

    /// Two records conflict when they talk about the same thing (enough shared words)
    /// and either use opposite words or name different dates.
    static func conflicts(_ a: MemoryItem, _ b: MemoryItem) -> Bool {
        let overlap = MemoryService.jaccard(
            MemoryService.tokenSet(a.content), MemoryService.tokenSet(b.content)
        )
        guard overlap >= 0.3 else { return false }
        if hasOppositePair(a.content, b.content) { return true }
        let datesA = dates(in: a.content)
        let datesB = dates(in: b.content)
        return !datesA.isEmpty && !datesB.isEmpty && datesA != datesB
    }

    static func hasOppositePair(_ a: String, _ b: String) -> Bool {
        let left = MemoryService.tokenSet(a)
        let right = MemoryService.tokenSet(b)
        for (first, second) in opposites {
            if (left.contains(first) && right.contains(second))
                || (left.contains(second) && right.contains(first)) {
                return true
            }
        }
        return false
    }

    /// The suffix shown next to the record.
    static func suffix(_ id: Int64, marks: [Int64: Int64]) -> String {
        marks[id].map { " ⚠ противоречит #\($0)" } ?? ""
    }
}
