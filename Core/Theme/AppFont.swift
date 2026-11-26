import AppKit
import SwiftUI

/// The interface is SF Pro; monospace is for code, paths and identifiers.
///
/// Nordwand Mono stays available as an option ("моноширинный интерфейс") and is still
/// the code face, so the character of the app is not thrown away — it just stops being
/// the only voice.
enum AppFont {
    static let bundledFamily = "Nordwand Mono"
    static let familyKey = "fontFamily"
    /// Step 3: off by default, so the interface follows the system font.
    static let monoInterfaceKey = "monoInterface"

    nonisolated(unsafe) private static var didRegister = false

    @MainActor
    static func register() {
        guard !didRegister else { return }
        didRegister = true

        let urls = Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: nil)
            ?? Bundle.main.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts")
            ?? []

        for url in urls where url.lastPathComponent.hasPrefix("NordwandMono") {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    /// The code face: the bundled mono unless the person chose another family.
    static var family: String {
        let stored = UserDefaults.standard.string(forKey: familyKey)
        guard let stored, !stored.isEmpty, NSFont(name: stored, size: 13) != nil else {
            return bundledFamily
        }
        return stored
    }

    static var usesMonoInterface: Bool {
        UserDefaults.standard.bool(forKey: monoInterfaceKey)
    }

    /// Extra leading on top of the font's natural line height (~1.32 em). Computed, not
    /// fixed, so the ratio holds at every size — and `StyleTests` pins it.
    static func lineSpacing(for size: CGFloat) -> CGFloat {
        max((size * 0.20).rounded(), 1)
    }

    static func isAvailable(_ family: String) -> Bool {
        NSFont(name: family, size: 13) != nil
    }

    /// Interface text: SF Pro, or the chosen mono when the option is on.
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        if usesMonoInterface {
            return mono(size, weight: weight)
        }
        return .system(size: size, weight: weight)
    }

    /// Chrome at the system size. The transcript has its own user-set size; the toolbar,
    /// pills and captions must not grow with it.
    static func chrome(_ size: CGFloat = 11, weight: Font.Weight = .regular) -> Font {
        ui(size, weight: weight)
    }

    /// Code, file paths, tool names, ids.
    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        let family = family
        guard isAvailable(family) else {
            return .system(size: size, weight: weight, design: .monospaced)
        }
        return .custom(family, size: size).weight(weight)
    }

    static func nsMono(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if let font = NSFont(name: family, size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    /// The composer's text view follows the interface face.
    static func nsUI(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        if usesMonoInterface, let font = NSFont(name: family, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// Every installed family, sorted.
    static func installedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
