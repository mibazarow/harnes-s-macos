import AppKit
import ApplicationServices
import CoreGraphics

extension ToolRegistry {
    func clipboardTool(_ args: [String: Any]) -> ToolResult {
        let board = NSPasteboard.general
        switch (args["action"] as? String)?.lowercased() ?? "read" {
        case "read": return .ok(Clipboard.summary(board))
        case "types": return .ok(Clipboard.types(board))
        case "write":
            guard let text = args["text"] as? String else { return .fail("text обязателен") }
            return .ok(Clipboard.write(text, to: board))
        case "clear":
            board.clearContents()
            return .ok("Буфер очищен.")
        default:
            return .fail("action: read | write | types | clear")
        }
    }

    func keyboardTool(_ args: [String: Any]) -> ToolResult {
        guard InputAccess.isTrusted else { return .fail(InputAccess.refusal) }
        let action = (args["action"] as? String)?.lowercased() ?? ""
        switch action {
        case "type":
            guard let text = args["text"] as? String, !text.isEmpty else {
                return .fail("text обязателен")
            }
            guard Self.typeText(text) else { return .fail("Не удалось отправить текст.") }
            return .ok("Набрано \(text.count) символов.")
        case "combo":
            guard let raw = args["combo"] as? String, let combo = KeyComboParser.parse(raw) else {
                return .fail("combo не разобран: пример cmd+shift+4")
            }
            Self.post(combo)
            return .ok("Отправлено \(raw).")
        case "key":
            guard let raw = (args["key"] as? String)?.lowercased(),
                  let code = KeyboardKey.codes[raw] else {
                return .fail("Неизвестная клавиша. Примеры: return, tab, escape, left, f5")
            }
            Self.post(KeyCombo(flags: [], key: code))
            return .ok("Нажата \(raw).")
        default:
            return .fail("action: type | key | combo")
        }
    }

    /// Unicode goes through `CGEventKeyboardSetUnicodeString`: per-character keycodes do
    /// not cover Cyrillic or emoji, and switching the user's layout is not acceptable.
    static func typeText(_ text: String) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return false }
        for character in text {
            var units = Array(String(character).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        return true
    }

    static func post(_ combo: KeyCombo) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: combo.key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: combo.key, keyDown: false) else {
            return
        }
        down.flags = combo.flags
        up.flags = combo.flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}


extension ToolRegistry {
    func permissionsTool() -> ToolResult {
        .ok(PermissionsReport.text(for: PermissionsReport.current))
    }
}


extension ToolRegistry {
    func notifyTool(_ args: [String: Any]) async -> ToolResult {
        switch (args["action"] as? String)?.lowercased() ?? "send" {
        case "read":
            guard let snapshot = Self.notificationCenterTree() else {
                return .fail("Центр уведомлений не читается: нужен грант Accessibility "
                    + "и запущенный Notification Center.")
            }
            let entries = NotificationDigest.entries(from: snapshot)
            guard !entries.isEmpty else { return .ok("Уведомлений нет.") }
            let lines = entries.map { entry -> String in
                if entry.redacted {
                    return "\(entry.path.description) redacted: true (приватное уведомление)"
                }
                return "\(entry.path.description) \(entry.title)"
                    + (entry.body.isEmpty ? "" : " — \(entry.body)")
            }
            return .ok("\(entries.count) уведомлений:\n" + lines.joined(separator: "\n"))

        case "dismiss":
            guard let path = Self.path(args) else { return .fail("path обязателен (из notify read).") }
            guard let snapshot = Self.notificationCenterTree() else {
                return .fail("Центр уведомлений не читается (Accessibility).")
            }
            guard let closePath = NotificationActions.closePath(in: snapshot, matching: path) else {
                return .fail("У уведомления \(path.description) нет кнопки закрытия; "
                    + "закрой его через ui click по пути.")
            }
            guard let pid = Self.notificationCenterPID() else {
                return .fail("Notification Center не запущен.")
            }
            let root = AXUIElementCreateApplication(pid)
            guard let element = AXBridge.element(at: closePath, in: root) else {
                return .fail("Кнопка закрытия не найдена в AX.")
            }
            let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
            return status == .success ? .ok("Уведомление закрыто.") : .fail("AX отказал в нажатии.")

        case "clear":
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("notify clear требует confirm: true: человек может читать их прямо сейчас.")
            }
            guard let snapshot = Self.notificationCenterTree(),
                  let pid = Self.notificationCenterPID() else {
                return .fail("Центр уведомлений не читается (Accessibility).")
            }
            let root = AXUIElementCreateApplication(pid)
            var closed = 0
            for entry in NotificationDigest.entries(from: snapshot) {
                guard let closePath = NotificationActions.closePath(in: snapshot, matching: entry.path),
                      let element = AXBridge.element(at: closePath, in: root) else { continue }
                if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                    closed += 1
                }
            }
            return .ok("Закрыто уведомлений: \(closed).")

        default:
            guard let title = args["title"] as? String, !title.isEmpty else {
                return .fail("title обязателен (или action: read | dismiss | clear)")
            }
            let body = (args["body"] as? String) ?? ""
            if let failure = await NotificationService().send(title: title, body: body) {
                return .fail(failure)
            }
            return .ok("Уведомление отправлено.")
        }
    }

    static func notificationCenterPID() -> pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == "com.apple.notificationcenterui"
        }?.processIdentifier
    }

    static func notificationCenterTree() -> AXNode? {
        guard InputAccess.isTrusted, let pid = notificationCenterPID() else { return nil }
        var budget = 4_000
        let root = AXUIElementCreateApplication(pid)
        return AXBridge.snapshot(root, depth: 0, budget: &budget)
    }
}
