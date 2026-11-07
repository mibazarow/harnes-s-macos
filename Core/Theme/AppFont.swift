import AppKit
import SwiftUI

/// Nordwand Mono is bundled with the app. The user can switch to any installed
/// family in Settings; the choice persists in UserDefaults.
enum AppFont {
    static let bundledFamily = "Nordwand Mono"
    static let familyKey = "fontFamily"

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

    /// Selected family name, or the bundled one when unset/missing.
    static var family: String {
        let stored = UserDefaults.standard.string(forKey: familyKey)
        guard let stored, !stored.isEmpty, NSFont(name: stored, size: 13) != nil else {
            return bundledFamily
        }
        return stored
    }

    /// Extra leading on top of the font's natural line height (~1.32 em). It used to be
    /// 0.28 em, which gave a 160% line box and read as a wall of text; 0.20 em keeps the
    /// block at ~152% — 30% less added leading — and paragraphs carry the rest of the
    /// rhythm. Computed, not fixed, so the ratio holds at every size.
    static func lineSpacing(for size: CGFloat) -> CGFloat {
        max((size * 0.20).rounded(), 1)
    }

    static func isAvailable(_ family: String) -> Bool {
        NSFont(name: family, size: 13) != nil
    }

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

    /// Every installed family, sorted, monospaced-looking first.
    static func installedFamilies() -> [String] {
        NSFontManager.shared.availableFontFamilies
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}