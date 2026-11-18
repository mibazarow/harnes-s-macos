import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// R25.2: `screencapture -l` can return the wrong pixels for a window that is covered or
/// sits on another Space. ScreenCaptureKit takes the window's own frame, which also
/// fixes OCR of a window and the pixel fallback in R18.10.
enum WindowCapture {
    static var isAvailable: Bool {
        if #available(macOS 14.0, *) { return true }
        return false
    }

    /// Returns true only when a PNG was actually written. Every failure is silent here
    /// and the caller falls back to `screencapture`: this is a better path, not the only
    /// one, and the caller already reports the fallback's error.
    @available(macOS 14.0, *)
    static func capture(windowID: CGWindowID, to path: URL) async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false
            )
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return false
            }
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let configuration = SCStreamConfiguration()
            let scale = max(1, CGFloat(filter.pointPixelScale))
            configuration.width = max(1, Int(window.frame.width * scale))
            configuration.height = max(1, Int(window.frame.height * scale))
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration
            )
            let representation = NSBitmapImageRep(cgImage: image)
            guard let data = representation.representation(using: .png, properties: [:]) else {
                return false
            }
            try data.write(to: path)
            return true
        } catch {
            return false
        }
    }
}
