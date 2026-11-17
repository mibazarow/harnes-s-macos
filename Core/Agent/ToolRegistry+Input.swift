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
