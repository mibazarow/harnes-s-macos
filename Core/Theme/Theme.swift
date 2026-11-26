import AppKit
import SwiftUI

/// A view never knows what "orange" means: it asks for a role.
///
/// There is one theme, Copper, and it is always dark. The app has no appearance choice:
/// no system/light/dark variants and no setting to pick between them.
struct ThemeTokens: Equatable, Sendable {
    var id: String
    /// Always `.dark`. Kept as a field so the window can pin its appearance in one place.
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
    var destructive: Color
    var warning: Color
    var success: Color
    var selection: Color

    var reasoningBackground: Color
    var codeBackground: Color
    /// The user's own messages sit on a slightly different shade, so the transcript
    /// makes "where I wrote" and "where it answered" obvious at a glance.
    var userBubble: Color
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
            scheme: .dark,
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
            destructive: palette.number,
            warning: palette.reasoning,
            success: Color(hex: 0x2FA84F),
            selection: palette.accent,
            reasoningBackground: palette.reasoningBackground,
            codeBackground: palette.codeBackground,
            userBubble: palette.userBackground,
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
/// `SyntaxHighlighter` takes this type directly; the default value is the Copper dark
/// palette, so a plain `Palette()` is the app's only palette.
struct Palette: Equatable, Sendable {
    var background = Color(hex: 0x0D0D10)
    var panel = Color(hex: 0x16161A)
    var codeBackground = Color(hex: 0x1B1A1E)
    var border = Color(hex: 0x2A2724)
    var text = Color(hex: 0xE2D8CD)
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
