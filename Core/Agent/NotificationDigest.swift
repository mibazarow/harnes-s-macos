import Foundation

/// R26.4: what the system told the person. The AX tree of Notification Center is the
/// only readable source; private notifications arrive with an empty description, and that
/// is reported as `redacted` instead of an empty line.
struct NotificationEntry: Equatable, Sendable {
    let path: [Int]
    let title: String
    let body: String
    let redacted: Bool
}

enum NotificationDigest {
    private static let textRoles: Set<String> = ["AXStaticText", "AXTextField", "AXHeading"]

    static func entries(from root: AXNode, limit: Int = 40) -> [NotificationEntry] {
        var found: [NotificationEntry] = []
        walk(root, limit: limit, into: &found)
        return found
    }

    private static func walk(_ node: AXNode, limit: Int, into found: inout [NotificationEntry]) {
        guard found.count < limit else { return }
        if let entry = entry(for: node) {
            found.append(entry)
            return
        }
        for child in node.children {
            guard found.count < limit else { return }
            walk(child, limit: limit, into: &found)
        }
    }

    /// A notification is a group whose subtree carries text. Groups without text but with
    /// children are the redacted ones: they exist on screen and say nothing.
    private static func entry(for node: AXNode) -> NotificationEntry? {
        guard ["AXGroup", "AXRow", "AXWindow"].contains(node.role) else { return nil }
        let texts = collectText(node)
        let hasGroupChild = node.children.contains {
            ["AXGroup", "AXRow"].contains($0.role) && !collectText($0).isEmpty
        }
        guard !hasGroupChild else { return nil }
        guard !texts.isEmpty else {
            // A notification with no readable text: the system marks it private, and the
            // group usually keeps its identifier even when every label is empty.
            guard !node.identifier.isEmpty else { return nil }
            return NotificationEntry(path: node.path, title: node.title, body: "", redacted: true)
        }
        let title = texts[0]
        let body = texts.dropFirst().joined(separator: " ")
        return NotificationEntry(path: node.path, title: title, body: body, redacted: false)
    }

    private static func collectText(_ node: AXNode) -> [String] {
        var texts: [String] = []
        func visit(_ node: AXNode, depth: Int) {
            guard depth < 6, texts.count < 8 else { return }
            if textRoles.contains(node.role) {
                let text = node.value.isEmpty ? node.title : node.value
                if !text.isEmpty, !texts.contains(text) { texts.append(text) }
            }
            for child in node.children { visit(child, depth: depth + 1) }
        }
        for child in node.children { visit(child, depth: 0) }
        return texts
    }
}

/// The close button of one notification, when the app exposes one.
enum NotificationActions {
    static func closePath(in root: AXNode, matching path: [Int]) -> [Int]? {
        guard let node = find(root, path: path) else { return nil }
        return closeButton(in: node)
    }

    private static func find(_ node: AXNode, path: [Int]) -> AXNode? {
        if node.path == path { return node }
        for child in node.children {
            if let found = find(child, path: path) { return found }
        }
        return nil
    }

    private static func closeButton(in node: AXNode) -> [Int]? {
        if node.role == "AXButton", node.identifier.lowercased().contains("close") {
            return node.path
        }
        for child in node.children {
            if let found = closeButton(in: child) { return found }
        }
        return nil
    }
}
