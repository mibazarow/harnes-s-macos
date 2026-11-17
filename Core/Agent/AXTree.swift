import ApplicationServices
import Foundation

/// A snapshot of an accessibility subtree. Pure data so rendering and search are
/// testable without a window server (R18.2).
struct AXNode: Sendable, Equatable {
    var role: String
    var title: String
    var value: String
    var identifier: String
    var position: CGPoint?
    var size: CGSize?
    var enabled: Bool
    var path: [Int]
    var children: [AXNode]

    var center: CGPoint? {
        guard let position, let size else { return nil }
        return CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    }

    /// `depth` counts from this node; decorative leaves are dropped to keep the tree
    /// small enough for a model to read.
    func lines(depth: Int, maxNodes: Int, budget: inout Int) -> [String] {
        guard budget > 0 else { return [] }
        budget -= 1
        var text = "\(String(repeating: "  ", count: depth))\(path.description) \(role)"
        if !title.isEmpty { text += " «\(title)»" }
        if !value.isEmpty { text += " value=\(value.prefix(80))" }
        if !identifier.isEmpty { text += " #\(identifier)" }
        if let position, let size {
            text += " \(Int(position.x)),\(Int(position.y)) \(Int(size.width))×\(Int(size.height))"
        }
        if !enabled { text += " disabled" }
        var result = [text]
        guard depth < 7 else { return result }
        for child in children where budget > 0 {
            result += child.lines(depth: depth + 1, maxNodes: maxNodes, budget: &budget)
        }
        return result
    }

    /// Depth-first search over role/title/value/identifier. `regex` switches matching
    /// mode; an invalid pattern matches nothing.
    func search(_ query: String, regex: Bool, limit: Int, budget: inout Int) -> [AXNode] {
        guard budget > 0, limit > 0 else { return [] }
        budget -= 1
        var found: [AXNode] = []
        if isMatch(query, regex: regex) { found.append(self) }
        for child in children {
            guard found.count < limit else { break }
            found += child.search(query, regex: regex, limit: limit - found.count, budget: &budget)
        }
        return found
    }

    private func isMatch(_ query: String, regex: Bool) -> Bool {
        let fields = [role, title, value, identifier]
        if regex {
            guard let expression = try? NSRegularExpression(pattern: query, options: [.caseInsensitive]) else {
                return false
            }
            return fields.contains { field in
                expression.firstMatch(in: field, range: NSRange(field.startIndex..., in: field)) != nil
            }
        }
        return fields.contains { $0.localizedCaseInsensitiveContains(query) }
    }
}

enum AXBridge {
    static func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    static func string(_ element: AXUIElement, _ key: String) -> String {
        (attribute(element, key) as? String) ?? ""
    }

    static func frame(_ element: AXUIElement) -> (CGPoint, CGSize)? {
        var point = CGPoint.zero
        var size = CGSize.zero
        var hasPoint = false
        var hasSize = false
        if let raw = attribute(element, kAXPositionAttribute) {
            hasPoint = AXValueGetValue(raw as! AXValue, .cgPoint, &point)
        }
        if let raw = attribute(element, kAXSizeAttribute) {
            hasSize = AXValueGetValue(raw as! AXValue, .cgSize, &size)
        }
        return hasPoint && hasSize ? (point, size) : nil
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func snapshot(_ element: AXUIElement, path: [Int] = [], depth: Int = 0,
                         budget: inout Int) -> AXNode {
        budget -= 1
        let role = string(element, kAXRoleAttribute)
        let title = string(element, kAXTitleAttribute)
        let value = string(element, kAXValueAttribute)
        let identifier = string(element, kAXIdentifierAttribute)
        let enabled = (attribute(element, kAXEnabledAttribute) as? Bool) ?? true
        var node = AXNode(
            role: role, title: title, value: value, identifier: identifier,
            position: nil, size: nil, enabled: enabled, path: path, children: []
        )
        if let frame = frame(element) {
            node.position = frame.0
            node.size = frame.1
        }
        guard depth < 8, budget > 0 else { return node }
        var index = 0
        for child in children(element) {
            guard budget > 0 else { break }
            node.children.append(snapshot(child, path: path + [index], depth: depth + 1, budget: &budget))
            index += 1
        }
        return node
    }

    static func element(at path: [Int], in root: AXUIElement) -> AXUIElement? {
        var current = root
        for index in path {
            let kids = children(current)
            guard index >= 0, index < kids.count else { return nil }
            current = kids[index]
        }
        return current
    }
}
