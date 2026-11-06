import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let fontSize = "fontSize"
        static let fontFamily = "fontFamily"
        static let lineSpacing = "lineSpacing"
        static let showTimestamps = "showTimestamps"
        static let compactionThresholdPercent = "compactionThresholdPercent"
        static let autopilot = "autopilot"
    }

    private let defaults: UserDefaults

    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Key.fontSize) }
    }

    var fontFamily: String {
        didSet {
            defaults.set(fontFamily, forKey: Key.fontFamily)
            defaults.set(fontFamily, forKey: AppFont.defaultsKey)
        }
    }

    var lineSpacing: Double {
        didSet {
            defaults.set(lineSpacing, forKey: Key.lineSpacing)
            defaults.set(lineSpacing, forKey: AppFont.lineSpacingKey)
        }
    }

    var showTimestamps: Bool {
        didSet { defaults.set(showTimestamps, forKey: Key.showTimestamps) }
    }

    var compactionThresholdPercent: Double {
        didSet { defaults.set(compactionThresholdPercent, forKey: Key.compactionThresholdPercent) }
    }

    var autopilot: Bool {
        didSet { defaults.set(autopilot, forKey: Key.autopilot) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let storedFontSize = defaults.double(forKey: Key.fontSize)
        self.fontSize = storedFontSize > 0 ? storedFontSize : 13

        let storedFamily = defaults.string(forKey: Key.fontFamily) ?? AppFont.bundledFamily
        self.fontFamily = storedFamily
        defaults.set(storedFamily, forKey: AppFont.defaultsKey)

        let storedLineSpacing = defaults.double(forKey: Key.lineSpacing)
        let resolvedSpacing = storedLineSpacing > 0 ? storedLineSpacing : 3
        self.lineSpacing = resolvedSpacing
        defaults.set(resolvedSpacing, forKey: AppFont.lineSpacingKey)

        if defaults.object(forKey: Key.showTimestamps) == nil {
            self.showTimestamps = true
        } else {
            self.showTimestamps = defaults.bool(forKey: Key.showTimestamps)
        }

        let storedThreshold = defaults.double(forKey: Key.compactionThresholdPercent)
        self.compactionThresholdPercent = storedThreshold > 0 ? storedThreshold : 80
        self.autopilot = defaults.bool(forKey: Key.autopilot)
    }
}