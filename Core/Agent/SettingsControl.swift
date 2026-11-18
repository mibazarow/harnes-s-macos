import AppKit
import Foundation

/// R25.10: the shell around the apps — theme, wallpaper, Dock, menu bar, hot corners,
/// Focus, screensaver, accessibility. `defaults` is used only where there is no public
/// API, and the value is always read back: "переключил" без чтения — это ложь.
enum AppearanceChoice: String, CaseIterable, Sendable {
    case dark, light, auto

    static func parse(_ raw: String?) -> AppearanceChoice? {
        guard let raw else { return nil }
        return AppearanceChoice(rawValue: raw.lowercased())
    }

    var command: String {
        switch self {
        case .dark: return "defaults write -g AppleInterfaceStyle -string Dark"
        case .light, .auto: return "defaults delete -g AppleInterfaceStyle"
        }
    }

    /// What `defaults read -g AppleInterfaceStyle` says after the write.
    var expected: String? {
        self == .dark ? "Dark" : nil
    }
}

enum SolidColor {
    /// `#RRGGBB` or `RRGGBB`; nil when the string is not a colour.
    static func parse(_ raw: String) -> NSColor? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func image(_ color: NSColor, size: NSSize = NSSize(width: 64, height: 64)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
}

enum DockControl {
    static let positions: Set<String> = ["left", "bottom", "right"]

    /// `defaults` key and value for one dock knob.
    static func write(_ knob: String, value: String) -> (key: String, value: String)? {
        switch knob {
        case "autohide": return ("autohide", value == "on" || value == "true" ? "true" : "false")
        case "position": return positions.contains(value) ? ("orientation", value) : nil
        case "size":
            guard let size = Int(value), (16...128).contains(size) else { return nil }
            return ("tilesize", String(size))
        case "magnification":
            guard let size = Int(value), (16...256).contains(size) else { return nil }
            return ("largesize", String(size))
        default: return nil
        }
    }
}

enum HotCorner {
    static let corners: [String: String] = [
        "top-left": "tl", "top-right": "tr",
        "bottom-left": "bl", "bottom-right": "br"
    ]

    /// The numbers are the ones System Settings writes.
    static let actions: [String: Int] = [
        "none": 0, "mission_control": 2, "application_windows": 3,
        "desktop": 4, "screensaver": 5, "disable_screensaver": 6,
        "launchpad": 11, "notification_center": 12
    ]

    static func key(corner: String) -> String? {
        guard let code = corners[corner.lowercased()] else { return nil }
        return "wvous-\(code)-corner"
    }

    static func modifierKey(corner: String) -> String? {
        guard let code = corners[corner.lowercased()] else { return nil }
        return "wvous-\(code)-modifier"
    }
}
