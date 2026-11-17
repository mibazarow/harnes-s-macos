import AppKit
import ApplicationServices
import CoreGraphics

/// Keyboard primitives for R18.4: a combo parser, a keycode table and a privacy check.
/// Posting needs the Accessibility grant; the parser and table do not.
enum KeyboardKey {
    static let codes: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "tab": 48, "escape": 53, "esc": 53, "space": 49,
        "delete": 51, "backspace": 51, "forwarddelete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
        "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
        "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]
}

struct KeyCombo: Equatable {
    var flags: CGEventFlags
    var key: CGKeyCode
}

enum KeyComboParser {
    static func parse(_ raw: String) -> KeyCombo? {
        let parts = raw.lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count >= 1, let last = parts.last, !last.isEmpty else { return nil }

        var flags: CGEventFlags = []
        var seen = Set<String>()
        for modifier in parts.dropLast() {
            guard seen.insert(modifier).inserted else { return nil }
            switch modifier {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option", "opt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: return nil
            }
        }
        guard let key = KeyboardKey.codes[last] else { return nil }
        return KeyCombo(flags: flags, key: key)
    }
}

enum InputAccess {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static let settingsURL =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"

    static let refusal = "Нет гранта Accessibility: нажатия и ввод клавиатуры недоступны. "
        + "Выдай разрешение в «Конфиденциальность и безопасность → Универсальный доступ» "
        + "(\(settingsURL)) и повтори. Программно грант не выдаётся."
}

/// R18.7: a pasteboard wrapper with a seam for tests — the app uses `.general`, tests
/// use a named board so a test run cannot clobber the user's clipboard.
enum Clipboard {
    static func summary(_ board: NSPasteboard) -> String {
        let types = (board.types ?? []).map(\.rawValue).sorted()
        guard !types.isEmpty else { return "Буфер пуст." }
        let text = board.string(forType: .string)
        var out = "types: " + types.joined(separator: ", ")
        if let text {
            out += "\ntext (\(text.count) символов):\n" + String(text.prefix(4_000))
        }
        return out
    }

    static func types(_ board: NSPasteboard) -> String {
        let types = (board.types ?? []).map(\.rawValue).sorted()
        return types.isEmpty ? "Буфер пуст." : types.joined(separator: "\n")
    }

    static func write(_ text: String, to board: NSPasteboard) -> String {
        board.clearContents()
        board.setString(text, forType: .string)
        return "Записано \(text.count) символов в буфер."
    }
}
