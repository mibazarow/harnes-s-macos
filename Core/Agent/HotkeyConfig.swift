import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// R27.1: the assistant key. A separate combination from the stop hotkey (⌃⌥⌘.), so a
/// runaway loop and a new request never fight for the same chord.
struct HotkeyConfig: Equatable, Sendable {
    enum Modifier: String, CaseIterable, Sendable {
        case control, option, command, shift

        var carbon: UInt32 {
            switch self {
            case .control: return UInt32(controlKey)
            case .option: return UInt32(optionKey)
            case .command: return UInt32(cmdKey)
            case .shift: return UInt32(shiftKey)
            }
        }

        var symbol: String {
            switch self {
            case .control: return "⌃"
            case .option: return "⌥"
            case .command: return "⌘"
            case .shift: return "⇧"
            }
        }
    }

    let key: String
    let modifiers: Set<Modifier>

    static let `default` = HotkeyConfig(key: "space", modifiers: [.control, .option])

    var keyCode: UInt32? {
        KeyboardKey.codes[key].map(UInt32.init)
    }

    var label: String {
        Modifier.allCases.filter { modifiers.contains($0) }.map(\.symbol).joined()
            + key.uppercased()
    }

    /// `"ctrl+alt+space"`, `"cmd+shift+k"`. The order of modifiers does not matter.
    static func parse(_ raw: String) -> HotkeyConfig? {
        let parts = raw.lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let key = parts.last, !key.isEmpty, KeyboardKey.codes[key] != nil else { return nil }
        var modifiers: Set<Modifier> = []
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control": modifiers.insert(.control)
            case "alt", "option", "opt": modifiers.insert(.option)
            case "cmd", "command", "meta": modifiers.insert(.command)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }
        guard !modifiers.isEmpty else { return nil }
        return HotkeyConfig(key: key, modifiers: modifiers)
    }

    var carbonModifiers: UInt32 {
        modifiers.reduce(0) { $0 | $1.carbon }
    }

    /// The panel is suppressed while these apps are frontmost: an assistant that pops up
    /// over the editor mid-keystroke is worse than no assistant.
    static func shouldShow(frontmostBundleID: String?, excluded: [String]) -> Bool {
        guard let frontmostBundleID else { return true }
        return !excluded.contains { frontmostBundleID.lowercased().contains($0.lowercased()) }
    }

    /// Selected text of the frontmost app, through AX. Nil when nothing is selected or the
    /// app does not expose it.
    static func selectedText() -> String? {
        guard InputAccess.isTrusted,
              let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        guard let raw = AXBridge.attribute(root, kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = raw as! AXUIElement
        guard let text = AXBridge.attribute(element, kAXSelectedTextAttribute as String) as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }
}
