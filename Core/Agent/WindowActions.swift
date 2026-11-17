import AppKit
import ApplicationServices
import CoreGraphics

/// R18.5: window actions through AX. `CGWindowID` is what `screenshot` takes, so the
/// window is looked up by its AX `AXWindowNumber` instead of asking the user for a pid.
enum WindowActions {
    static func element(for windowID: Int) -> (AXUIElement, pid_t)? {
        for app in NSWorkspace.shared.runningApplications {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            guard let windows = AXBridge.attribute(root, kAXWindowsAttribute) as? [AXUIElement] else {
                continue
            }
            for window in windows {
                if let number = AXBridge.attribute(window, "AXWindowNumber") as? Int,
                   number == windowID {
                    return (window, app.processIdentifier)
                }
            }
        }
        return nil
    }

    static func setFrame(_ element: AXUIElement, position: CGPoint? = nil, size: CGSize? = nil) -> Bool {
        var ok = true
        if let position {
            var value = position
            if let ax = AXValueCreate(.cgPoint, &value) {
                ok = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, ax) == .success && ok
            }
        }
        if let size {
            var value = size
            if let ax = AXValueCreate(.cgSize, &value) {
                ok = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, ax) == .success && ok
            }
        }
        return ok
    }

    static func press(_ element: AXUIElement, attribute: String) -> Bool {
        guard let button = AXBridge.attribute(element, attribute) else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
    }

    /// Fits the window into the display with a small margin, keeping its aspect ratio.
    static func fitted(size: CGSize, into display: DisplaySpace) -> CGSize {
        let margin: CGFloat = 40
        let maxWidth = max(display.size.width - margin * 2, 200)
        let maxHeight = max(display.size.height - margin * 2, 200)
        guard size.width > maxWidth || size.height > maxHeight else { return size }
        let scale = min(maxWidth / size.width, maxHeight / size.height)
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    static func origin(for size: CGSize, in display: DisplaySpace) -> CGPoint {
        CGPoint(
            x: display.origin.x + max((display.size.width - size.width) / 2, 20),
            y: display.origin.y + max((display.size.height - size.height) / 2, 20)
        )
    }
}
