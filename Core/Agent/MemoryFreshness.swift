import Foundation

/// R34.1: the prompt block keeps its stable order, but a fresh or corrected record says
/// so.
///
/// Sorting by date would break the provider's prefix cache on every write (M37). A short
/// label carries the same information without moving a line: `[новое]` for records
/// younger than a week, `[обновлено]` for one that replaced an older record through
/// `supersedes_id`.
enum MemoryFreshness {
    static let freshDays = 7
    /// Four labels is 40 characters: the ceiling the task allows for the whole block.
    static let maxLabels = 4
    static let fresh = "[новое]"
    static let updated = "[обновлено]"

    static func label(_ item: MemoryItem, now: Date) -> String? {
        if item.supersedesID != nil { return updated }
        guard let created = ISO8601DateFormatter().date(from: item.createdAt) else { return nil }
        let age = now.timeIntervalSince(created)
        return age >= 0 && age < Double(freshDays) * 86_400 ? fresh : nil
    }

    /// Labels in the order the records are shown, capped so the block cannot grow by
    /// more than `maxLabels * 10` characters.
    static func labels(_ items: [MemoryItem], now: Date = Date()) -> [Int64: String] {
        var result: [Int64: String] = [:]
        for item in items {
            guard result.count < maxLabels, let label = label(item, now: now) else { continue }
            result[item.id] = label
        }
        return result
    }
}
