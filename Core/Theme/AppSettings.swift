import Foundation
import Observation

@MainActor
@Observable
final class AppSettings {
    private enum Key {
        static let fontSize = "fontSize"
        static let theme = "appearanceTheme"

        static let showTimestamps = "showTimestamps"
        static let compactionThresholdPercent = "compactionThresholdPercent"
        static let autopilot = "autopilot"
    }

    private let defaults: UserDefaults

    var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: Key.theme) }
    }

    var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Key.fontSize) }
    }

    var fontFamily: String {
        didSet { defaults.set(fontFamily, forKey: AppFont.familyKey) }
    }

    /// Step 3: off by default. When on, the interface uses Nordwand Mono again.
    var monoInterface: Bool {
        didSet { defaults.set(monoInterface, forKey: AppFont.monoInterfaceKey) }
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

    /// Raw "provider id + model" from the Providers tab. Empty means "not chosen yet".
    var mainModel: String {
        didSet { defaults.set(mainModel, forKey: ModelSelection.mainModelKey) }
    }

    var subagentModel: String {
        didSet { defaults.set(subagentModel, forKey: ModelSelection.subagentModelKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Step 2: the system theme is the default; Copper stays as an option.
        self.theme = AppTheme(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system

        let storedFontSize = defaults.double(forKey: Key.fontSize)
        self.fontSize = storedFontSize > 0 ? storedFontSize : FontSize.transcriptDefault

        self.fontFamily = defaults.string(forKey: AppFont.familyKey) ?? AppFont.bundledFamily
        self.monoInterface = defaults.bool(forKey: AppFont.monoInterfaceKey)

        if defaults.object(forKey: Key.showTimestamps) == nil {
            self.showTimestamps = true
        } else {
            self.showTimestamps = defaults.bool(forKey: Key.showTimestamps)
        }

        let storedThreshold = defaults.double(forKey: Key.compactionThresholdPercent)
        self.compactionThresholdPercent = storedThreshold > 0 ? storedThreshold : 80
        self.autopilot = defaults.bool(forKey: Key.autopilot)
        self.mainModel = defaults.string(forKey: ModelSelection.mainModelKey) ?? ""
        self.subagentModel = defaults.string(forKey: ModelSelection.subagentModelKey) ?? ""
    }
}
