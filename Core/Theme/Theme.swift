import SwiftUI

enum AppTheme: String, CaseIterable, Sendable {
    case dark, light

    var palette: Palette { self == .dark ? .dark : .light }
}

/// Copper colors are shared by both appearances without changing layout.
struct Palette: Equatable, Sendable {
    var scheme: ColorScheme = .dark

    var background = Color(hex: 0x0D0D10)
    var panel = Color(hex: 0x16161A)
    var codeBackground = Color(hex: 0x1B1A1E)
    var border = Color(hex: 0x2A2724)
    /// Text of the user's own messages — warm near-white.
    var text = Color(hex: 0xE2D8CD)
    /// Slightly softer tone for long assistant answers, so they do not glare.
    var assistantText = Color(hex: 0xCFC4B8)
    var dim = Color(hex: 0x9C9086)
    var faint = Color(hex: 0x6B6159)

    var accent = Color(hex: 0xB87333)
    var reasoning = Color(hex: 0xD9A05F)
    var reasoningBackground = Color(hex: 0x1E1A15)
    var userBackground = Color(hex: 0x1F1B16)

    var keyword = Color(hex: 0xC98A54)
    var string = Color(hex: 0xB5A38B)
    var number = Color(hex: 0xD98C4A)
    var type = Color(hex: 0xD9B27A)
    var call = Color(hex: 0xE0B27F)
    var comment = Color(hex: 0x6B6159)
    var punctuation = Color(hex: 0xA89A8C)

    static let dark = Palette()
    static let current = dark
    static let light: Palette = {
        var p = Palette()
        p.scheme = .light
        p.background = Color(hex: 0xFAF8F5)
        p.panel = Color(hex: 0xFFFFFF)
        p.codeBackground = Color(hex: 0xF4F1EC)
        p.border = Color(hex: 0xE6E1DA)
        p.text = Color(hex: 0x1F1B17)
        p.assistantText = Color(hex: 0x40382F)
        p.dim = Color(hex: 0x6B6159)
        p.faint = Color(hex: 0x70665D)
        p.accent = Color(hex: 0xA65A1E)
        p.reasoning = Color(hex: 0x8A5A22)
        p.reasoningBackground = Color(hex: 0xFBF2E6)
        p.userBackground = Color(hex: 0xF3EEE7)
        p.keyword = Color(hex: 0x9B4A18)
        p.string = Color(hex: 0x4A6B3A)
        p.number = Color(hex: 0x8A5A22)
        p.type = Color(hex: 0x7A5A1E)
        p.call = Color(hex: 0x6B4A8A)
        p.comment = Color(hex: 0x70665D)
        p.punctuation = Color(hex: 0x70665D)
        return p
    }()
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
