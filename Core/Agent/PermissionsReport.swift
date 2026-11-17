import AppKit
import ApplicationServices

/// R18.0: the two grants every UI tool depends on, checked by code instead of assumed.
/// The panel is opened, not granted: TCC is written by the person, never by the app.
enum PermissionsReport {
    struct State: Equatable {
        var accessibility: Bool
        var screenRecording: Bool
        var processName: String
    }

    static let accessibilityPanel =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"
    static let screenPanel =
        "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"

    static var current: State {
        State(
            accessibility: AXIsProcessTrusted(),
            screenRecording: CGPreflightScreenCaptureAccess(),
            processName: ProcessInfo.processInfo.processName
        )
    }

    static func text(for state: State) -> String {
        var lines = [
            "process=\(state.processName)",
            "ax=\(state.accessibility)",
            "screen=\(state.screenRecording)"
        ]
        if !state.accessibility {
            lines.append("Accessibility: выдай разрешение в \(accessibilityPanel). "
                + "Без него клики, клавиши и AX-дерево возвращают отказ.")
        }
        if !state.screenRecording {
            lines.append("Screen Recording: выдай разрешение в \(screenPanel). "
                + "Без него screenshot и ocr отдают чёрный кадр.")
        }
        if state.accessibility, state.screenRecording {
            lines.append("Оба гранта на месте.")
        }
        return lines.joined(separator: "\n")
    }
}
