import AppKit
import SwiftUI

/// Colour identity of the app, separate from the appearance on screen.
///
/// `.system` and `.copper` follow the system appearance, so each has a light and a dark
/// rendering. `.light` and `.dark` force an appearance on the system colours.
enum AppTheme: String, CaseIterable, Sendable {
    case system
    case light
    case dark
    case copper

    var title: String {
        switch self {
        case .system: "Системная"
        case .light: "Светлая"
        case .dark: "Тёмная"
        case .copper: "Copper"
        }
    }

    var tokens: ThemeTokens {
        switch self {
        case .system: .system
        case .light: .systemLight
        case .dark: .systemDark
        case .copper: .copper
        }
    }
}

/// A view never knows what "orange" means: it asks for a role.
///
/// `Palette` stays as the syntax representation and as the Copper source, because code
/// highlighting is not system semantics: a keyword is a keyword in every theme.
struct ThemeTokens: Equatable, Sendable {
    var id: String
    /// `nil` means "follow the system appearance".
    var scheme: ColorScheme?

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
    static let system = ThemeTokens(
        id: "system",
        scheme: nil,
        windowBackground: Color(nsColor: .windowBackgroundColor),
        contentBackground: Color(nsColor: .textBackgroundColor),
        controlBackground: Color(nsColor: .controlBackgroundColor),
        separator: Color(nsColor: .separatorColor),
        labelPrimary: Color(nsColor: .labelColor),
        labelSecondary: Color(nsColor: .secondaryLabelColor),
        labelTertiary: Color(nsColor: .tertiaryLabelColor),
        labelQuaternary: Color(nsColor: .quaternaryLabelColor),
        accent: .accentColor,
        destructive: Color(nsColor: .systemRed),
        warning: Color(nsColor: .systemOrange),
        success: Color(nsColor: .systemGreen),
        selection: Color(nsColor: .selectedContentBackgroundColor),
        reasoningBackground: Color(nsColor: .underPageBackgroundColor),
        codeBackground: Color(nsColor: .controlBackgroundColor),
        // A quiet plate derived from the label colour. `windowBackground` and
        // `textBackground` resolve to the same white in light mode, so a system surface
        // colour gave no visible bubble there; a 7% label wash is one step off the
        // content background in both appearances and still follows Increase Contrast.
        userBubble: Color(nsColor: .labelColor).opacity(0.07),
        syntax: .xcode
    )

    static var systemDark: ThemeTokens {
        var tokens = system
        tokens.id = "dark"
        tokens.scheme = .dark
        return tokens
    }

    static var systemLight: ThemeTokens {
        var tokens = system
        tokens.id = "light"
        tokens.scheme = .light
        return tokens
    }

    /// Today's look, unchanged, rendered per appearance instead of pinned to one:
    /// `Palette.dark` for a dark system, `Palette.light` for a light one.
    static let copper: ThemeTokens = {
        func pair(_ path: KeyPath<Palette, Color>) -> Color {
            copperColor(light: Palette.light[keyPath: path], dark: Palette.dark[keyPath: path])
        }
        return ThemeTokens(
            id: "copper",
            scheme: nil,
            windowBackground: pair(\.background),
            contentBackground: pair(\.background),
            controlBackground: pair(\.panel),
            separator: pair(\.border),
            labelPrimary: pair(\.text),
            labelSecondary: pair(\.dim),
            labelTertiary: pair(\.faint),
            // Copper never had a fourth label; the faintest available tone is the point.
            labelQuaternary: pair(\.faint),
            accent: pair(\.accent),
            destructive: pair(\.number),
            warning: pair(\.reasoning),
            success: Color(nsColor: .systemGreen),
            selection: pair(\.accent),
            reasoningBackground: pair(\.reasoningBackground),
            codeBackground: pair(\.codeBackground),
            userBubble: pair(\.userBackground),
            // Syntax must follow the appearance too: dark Copper colours on the light
            // code plate were nearly unreadable.
            syntax: .copperAdaptive
        )
    }()
}

// MARK: - Environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = ThemeTokens.system
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

// MARK: - Palettes

/// Copper, and the syntax colours that go with a theme.
///
/// `SyntaxHighlighter` takes this type directly; the tests that pin code colours create
/// `Palette()` and keep working, because Copper is the default value.
struct Palette: Equatable, Sendable {
    var scheme: ColorScheme = .dark

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

    static let dark = Palette()
    static let copper = Palette()

    /// Each colour resolves per appearance, so one Copper theme is readable in both.
    static let copperAdaptive: Palette = {
        func pair(_ path: KeyPath<Palette, Color>) -> Color {
            copperColor(light: Palette.light[keyPath: path], dark: Palette.dark[keyPath: path])
        }
        var p = Palette()
        p.background = pair(\.background)
        p.panel = pair(\.panel)
        p.codeBackground = pair(\.codeBackground)
        p.border = pair(\.border)
        p.text = pair(\.text)
        p.assistantText = pair(\.assistantText)
        p.dim = pair(\.dim)
        p.faint = pair(\.faint)
        p.accent = pair(\.accent)
        p.reasoning = pair(\.reasoning)
        p.reasoningBackground = pair(\.reasoningBackground)
        p.userBackground = pair(\.userBackground)
        p.keyword = pair(\.keyword)
        p.string = pair(\.string)
        p.number = pair(\.number)
        p.type = pair(\.type)
        p.call = pair(\.call)
        p.comment = pair(\.comment)
        p.punctuation = pair(\.punctuation)
        return p
    }()

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

    /// Xcode-like syntax colours for the system theme: the palette a Mac user already
    /// reads every day, resolved per appearance.
    static let xcode: Palette = {
        var p = Palette()
        p.keyword = copperColor(light: Color(hex: 0xAD3DA4), dark: Color(hex: 0xFC5FA3))
        p.string = copperColor(light: Color(hex: 0xD12F1B), dark: Color(hex: 0xFC6A5D))
        p.number = copperColor(light: Color(hex: 0x272AD8), dark: Color(hex: 0xD0BF69))
        p.type = copperColor(light: Color(hex: 0x0B4F79), dark: Color(hex: 0x5DD8FF))
        p.call = copperColor(light: Color(hex: 0x326D74), dark: Color(hex: 0x67B7A4))
        p.comment = copperColor(light: Color(hex: 0x707F8C), dark: Color(hex: 0x7F8C98))
        p.punctuation = copperColor(light: Color(hex: 0x68696B), dark: Color(hex: 0xDEDEDE))
        return p
    }()

    init() {}
}

/// Resolves to a different colour per appearance, so one theme works in both.
func copperColor(light: Color, dark: Color) -> Color {
    let lightColor = NSColor(light).usingColorSpace(.sRGB) ?? .textColor
    let darkColor = NSColor(dark).usingColorSpace(.sRGB) ?? .textColor
    return Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? darkColor : lightColor
    })
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
