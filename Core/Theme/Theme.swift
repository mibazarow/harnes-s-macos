import AppKit
import SwiftUI

/// A view never knows what "orange" means: it asks for a role.
///
/// There is one theme, Copper, and it is always light: the "Пузыри" variant of
/// `design/chat-stand.html`. The app has no appearance choice: no system/light/dark
/// variants and no setting to pick between them.
struct ThemeTokens: Equatable, Sendable {
    var id: String
    /// Always `.light`. Kept as a field so the window can pin its appearance in one place.
    var scheme: ColorScheme

    var windowBackground: Color
    var contentBackground: Color
    var controlBackground: Color
    var separator: Color

    var labelPrimary: Color
    var labelSecondary: Color
    var labelTertiary: Color
    var labelQuaternary: Color

    var accent: Color
    /// Readable copper for tool names, inline code and links. The button `accent` is
    /// too light on these surfaces to carry text.
    var accentStrong: Color
    var destructive: Color
    var warning: Color
    var success: Color
    var selection: Color

    var reasoningBackground: Color
    var codeBackground: Color
    /// Both transcript roles sit in bubbles. The user's own words take a warm plate,
    /// the answer takes a white one, so "where I wrote" and "where it answered" are
    /// obvious without a role line.
    var userBubble: Color
    var userBubbleBorder: Color
    var assistantBubble: Color
    var assistantBubbleBorder: Color
    var syntax: Palette

    /// Text on top of `accent`, for filled buttons.
    var onAccent: Color {
        Color(nsColor: .alternateSelectedControlTextColor)
    }
}

extension ThemeTokens {
    static let copper: ThemeTokens = {
        let palette = Palette()
        return ThemeTokens(
            id: "copper",
            scheme: .light,
            windowBackground: palette.background,
            contentBackground: palette.background,
            controlBackground: palette.panel,
            separator: palette.border,
            labelPrimary: palette.text,
            labelSecondary: palette.dim,
            labelTertiary: palette.faint,
            // Copper never had a fourth label; the faintest available tone is the point.
            labelQuaternary: palette.faint,
            accent: palette.accent,
            accentStrong: palette.accentStrong,
            destructive: palette.destructive,
            warning: palette.warning,
            success: palette.success,
            selection: palette.accent,
            reasoningBackground: palette.reasoningBackground,
            codeBackground: palette.codeBackground,
            userBubble: palette.userBackground,
            userBubbleBorder: palette.userBubbleBorder,
            assistantBubble: palette.assistantBubble,
            assistantBubbleBorder: palette.assistantBubbleBorder,
            syntax: palette
        )
    }()
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ThemeTokens.copper
}

extension EnvironmentValues {
    var theme: ThemeTokens {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    func theme(_ tokens: ThemeTokens) -> some View {
        environment(\.theme, tokens)
    }
}

// MARK: - Palette

/// Copper, and the syntax colours that go with it.
///
/// The values are the light "Пузыри" variant of `design/chat-stand.html`.
/// `SyntaxHighlighter` takes this type directly; the default value is that palette, so
/// a plain `Palette()` is the app's only palette.
struct Palette: Equatable, Sendable {
    var background = Color(hex: 0xFBFAF8)
    var panel = Color(hex: 0xF4F2EE)
    var codeBackground = Color(hex: 0xEFEDE8)
    var border = Color(hex: 0xE1DCD4)
    var text = Color(hex: 0x23201C)
    var assistantText = Color(hex: 0x23201C)
    var dim = Color(hex: 0x635C54)
    var faint = Color(hex: 0x918879)

    var accent = Color(hex: 0xB0601B)
    /// Readable copper on light surfaces: tool names, inline code and links.
    var accentStrong = Color(hex: 0xA0510C)
    var destructive = Color(hex: 0xB0501E)
    var warning = Color(hex: 0xB0501E)
    var success = Color(hex: 0x2E7D32)
    var reasoningBackground = Color(hex: 0xF7F3EB)
    var userBackground = Color(hex: 0xF3E7D5)

    var userBubbleBorder = Color(hex: 0xE4D2B8)
    var assistantBubble = Color(hex: 0xFFFFFF)
    var assistantBubbleBorder = Color(hex: 0xE4DFD7)

    var keyword = Color(hex: 0x7B3FA0)
    var string = Color(hex: 0x4A6B1F)
    var number = Color(hex: 0xA0510C)
    var type = Color(hex: 0x1F5A96)
    var call = Color(hex: 0x1F5A96)
    var comment = Color(hex: 0x8C8479)
    var punctuation = Color(hex: 0x918879)

    init() {}
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
