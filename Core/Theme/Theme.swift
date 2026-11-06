import SwiftUI

/// HARNES-S uses one theme: dark "Copper" — obsidian background, warm copper accents.
/// No light mode, no system sync. Single source of truth.
struct Palette: Equatable, Sendable {
    let scheme: ColorScheme = .dark

    let background = Color(hex: 0x0D0D10)
    let panel = Color(hex: 0x16161A)
    let codeBackground = Color(hex: 0x1B1A1E)
    let border = Color(hex: 0x2A2724)
    /// Text of the user's own messages — warm near-white.
    let text = Color(hex: 0xE2D8CD)
    /// Slightly softer tone for long assistant answers, so they do not glare.
    let assistantText = Color(hex: 0xCFC4B8)
    let dim = Color(hex: 0x9C9086)
    let faint = Color(hex: 0x6B6159)

    let accent = Color(hex: 0xB87333)
    let reasoning = Color(hex: 0xD9A05F)
    let reasoningBackground = Color(hex: 0x1E1A15)
    let userBackground = Color(hex: 0x1F1B16)

    let keyword = Color(hex: 0xC98A54)
    let string = Color(hex: 0xB5A38B)
    let number = Color(hex: 0xD98C4A)
    let type = Color(hex: 0xD9B27A)
    let call = Color(hex: 0xE0B27F)
    let comment = Color(hex: 0x6B6159)
    let punctuation = Color(hex: 0xA89A8C)

    static let current = Palette()
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
