import ApplicationServices
import Foundation

/// A menu bar snapshot. Kept separate from AX so path resolution is testable: titles are
/// localized, so a path is matched by name at every level, never by index.
struct MenuNode: Sendable, Equatable {
    var title: String
    var enabled: Bool
    var children: [MenuNode]

    func listed(path: [String] = [], depth: Int = 0) -> [String] {
        guard depth < 3 else { return [] }
        var rows: [String] = []
        for child in children where !child.title.isEmpty {
            let nextPath = path + [child.title]
            rows.append(String(repeating: "  ", count: depth) + nextPath.joined(separator: " > "))
            rows += child.listed(path: nextPath, depth: depth + 1)
        }
        return rows
    }

    /// Returns the path of nodes to press: walk by title, compare case-insensitively and
    /// ignore separators. `nil` when any step is missing.
    func resolve(_ path: [String]) -> [MenuNode]? {
        guard let first = path.first else { return nil }
        guard let match = children.first(where: {
            $0.title.compare(first, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else { return nil }
        if path.count == 1 { return [match] }
        guard let rest = match.resolve(Array(path.dropFirst())) else { return nil }
        return [match] + rest
    }
}

enum MenuBridge {
    static func snapshot(_ root: AXUIElement, depth: Int = 0) -> MenuNode {
        let title = AXBridge.string(root, kAXTitleAttribute)
        let enabled = (AXBridge.attribute(root, kAXEnabledAttribute) as? Bool) ?? true
        guard depth < 4 else { return MenuNode(title: title, enabled: enabled, children: []) }
        let children = AXBridge.children(root).map { snapshot($0, depth: depth + 1) }
        return MenuNode(title: title, enabled: enabled, children: children)
    }
}
