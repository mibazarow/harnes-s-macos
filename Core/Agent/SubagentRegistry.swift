import Foundation

/// D8: named, bounded children with an explicit way to stop one.
///
/// The old closure had no identity: the parent could not say which child to stop, and a
/// child could not tell whether it had been stopped. Names are assigned here so they are
/// unique even when two spawns race.
/// Where the child's result goes. `caller` returns it only as the tool result;
/// `parent` additionally announces the child in the transcript.
enum SubagentDelivery: String, Sendable {
    case parent
    case caller
}

/// S4: what the header pill needs. A value snapshot, because SwiftUI cannot observe an
/// actor and a `ForEach` over an awaited result would never redraw.
struct SubagentInfo: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let startedAt: Date

    init(_ child: SubagentRegistry.Child) {
        self.id = child.id
        self.title = child.title
        self.startedAt = child.startedAt
    }
}

actor SubagentRegistry {
    struct Ticket: Sendable, Equatable {
        let id: String
        let depth: Int
    }

    struct Child: Sendable, Equatable {
        let id: String
        let parent: String?
        let depth: Int
        /// S0.5: a short Russian label for the pill; never the English prompt.
        var title: String
        /// S2: when the child was reserved, for "работает 1:47".
        let startedAt: Date
        var cancelled: Bool
        var reason: String?
    }

    static let root = "lead"

    let limit: Int
    let maxDepth: Int
    private var children: [String: Child] = [:]
    private var nextIndex = 1

    init(limit: Int = 4, maxDepth: Int = 2) {
        self.limit = max(1, limit)
        self.maxDepth = max(1, maxDepth)
    }

    var running: Int { children.count }

    /// Reserve a name before the work starts. The name is what an interrupt and a log
    /// line refer to; allocating it later would make both racy.
    func begin(parent: String?, title: String = "") throws -> Ticket {
        guard children.count < limit else {
            throw ConfigurationError.invalidArguments(
                "Лимит одновременных подагентов: \(limit). Дождись завершения одного."
            )
        }
        let depth = (parent.flatMap { children[$0]?.depth } ?? 0) + 1
        guard depth <= maxDepth else {
            throw ConfigurationError.invalidArguments(
                "Глубина подагентов ограничена \(maxDepth): дальше вложенность не растёт."
            )
        }
        let id = "agent-\(nextIndex)"
        nextIndex += 1
        children[id] = Child(
            id: id, parent: parent, depth: depth, title: title,
            startedAt: Date(), cancelled: false, reason: nil
        )
        return Ticket(id: id, depth: depth)
    }

    func end(_ id: String) {
        children.removeValue(forKey: id)
    }

    func isCancelled(_ id: String) -> Bool {
        children[id]?.cancelled ?? false
    }

    /// `user` may stop anything; an ancestor only its own descendants. Returns the line
    /// to show; a refused interrupt changes nothing.
    @discardableResult
    func interrupt(target: String, by caller: String, reason: String) -> String {
        guard var child = children[target] else {
            return "Подагент \(target) не найден."
        }
        if caller != "user" {
            guard isDescendant(target, of: caller) else {
                return "Нельзя прервать \(target): это не ваш потомок."
            }
        }
        child.cancelled = true
        child.reason = reason
        children[target] = child
        for id in children.keys where isDescendant(id, of: target) {
            children[id]?.cancelled = true
            children[id]?.reason = reason
        }
        return "Подагент \(target) прерван: \(reason)."
    }

    func snapshot() -> [Child] {
        children.values.sorted { $0.id < $1.id }
    }

    private func isDescendant(_ id: String, of ancestor: String) -> Bool {
        var current = children[id]?.parent
        while let parent = current {
            if parent == ancestor { return true }
            current = children[parent]?.parent
        }
        return false
    }
}
