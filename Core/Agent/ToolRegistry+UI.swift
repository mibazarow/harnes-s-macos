import AppKit
import ApplicationServices
import CoreGraphics

extension ToolRegistry {
    /// R18.2: read the AX tree and act on an element by path. Paths come from `tree` or
    /// `find`, so the model never has to guess coordinates.
    func uiTool(_ args: [String: Any]) -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "tree"
        guard let pid = Self.applicationPID(args) else {
            return .fail("Приложение не найдено. Передай app (имя или bundle id) или pid.")
        }
        guard InputAccess.isTrusted else { return .fail(InputAccess.refusal) }

        let root = AXUIElementCreateApplication(pid)
        switch action {
        case "tree":
            var budget = min(max(Self.int(args, "max_nodes") ?? 2_000, 50), 20_000)
            let maxDepth = min(max(Self.int(args, "depth") ?? 3, 1), 8)
            let node = AXBridge.snapshot(root, depth: 0, budget: &budget)
            var linesBudget = maxDepth * 0 + 100_000
            let lines = node.lines(depth: 0, maxNodes: budget, budget: &linesBudget)
            return .ok("pid=\(pid) узлов≈\(lines.count)\n" + lines.joined(separator: "\n"))
        case "find":
            guard let query = args["query"] as? String, !query.isEmpty else {
                return .fail("query обязателен")
            }
            var budget = 8_000
            let node = AXBridge.snapshot(root, depth: 0, budget: &budget)
            var searchBudget = 8_000
            let limit = min(max(Self.int(args, "limit") ?? 20, 1), 100)
            let found = node.search(
                query, regex: Self.bool(args, "regex") ?? false,
                limit: limit, budget: &searchBudget
            )
            guard !found.isEmpty else { return .ok("Ничего не найдено по «\(query)».") }
            return .ok(found.map { node in
                var line = "\(node.path.description) \(node.role)"
                if !node.title.isEmpty { line += " «\(node.title)»" }
                if let center = node.center {
                    line += " center=\(Int(center.x)),\(Int(center.y))"
                }
                if !node.enabled { line += " disabled" }
                return line
            }.joined(separator: "\n"))
        case "click":
            guard let path = Self.path(args), let element = AXBridge.element(at: path, in: root) else {
                return .fail("path не найден; сначала вызови ui tree или find.")
            }
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return .ok("Нажато: \(path.description)")
            }
            guard let frame = AXBridge.frame(element) else {
                return .fail("Элемент не поддерживает press и не имеет координат.")
            }
            let center = CGPoint(x: frame.0.x + frame.1.width / 2, y: frame.0.y + frame.1.height / 2)
            Self.click(at: center)
            return .ok("Press не поддерживается; клик по центру \(Int(center.x)),\(Int(center.y)).")
        case "set_value":
            guard let path = Self.path(args), let element = AXBridge.element(at: path, in: root) else {
                return .fail("path не найден.")
            }
            guard let value = args["value"] as? String else { return .fail("value обязателен") }
            let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
            return status == .success ? .ok("Значение установлено.") : .fail("AX отказал (код \(status.rawValue)).")
        case "focus":
            guard let path = Self.path(args), let element = AXBridge.element(at: path, in: root) else {
                return .fail("path не найден.")
            }
            NSRunningApplication(processIdentifier: pid)?.activate()
            let status = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return status == .success ? .ok("Фокус передан.") : .fail("AX отказал (код \(status.rawValue)).")
        default:
            return .fail("action: tree | find | click | set_value | focus")
        }
    }

    static func applicationPID(_ args: [String: Any]) -> pid_t? {
        if let pid = int(args, "pid") { return pid_t(pid) }
        let apps = NSWorkspace.shared.runningApplications
        if let query = (args["app"] as? String)?.lowercased(), !query.isEmpty {
            return apps.first {
                ($0.localizedName ?? "").lowercased().contains(query)
                    || ($0.bundleIdentifier ?? "").lowercased().contains(query)
            }?.processIdentifier
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func path(_ args: [String: Any]) -> [Int]? {
        guard let raw = args["path"] as? [Any] else { return nil }
        let values = raw.compactMap { value -> Int? in
            if let number = value as? Int { return number }
            if let number = value as? Double { return Int(number) }
            return nil
        }
        return values.count == raw.count ? values : nil
    }

    static func click(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
