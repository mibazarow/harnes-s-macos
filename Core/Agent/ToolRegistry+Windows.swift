import AppKit
import CoreGraphics

extension ToolRegistry {
    /// R20.1: windows used to be reachable only by compiling a Swift helper on the fly.
    /// Coordinates are returned in points (what AX and CGEvent use) and in pixels of the
    /// owning display (what a screenshot uses), so a click and a screenshot agree.
    func windowsTool(_ args: [String: Any]) -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "list"
        switch action {
        case "list":
            let filter = (args["app"] as? String)?.lowercased()
            let screens = Self.displays()
            let raw = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
            ) as? [[String: Any]] ?? []

            var lines: [String] = []
            for window in raw {
                guard (window[kCGWindowLayer as String] as? Int) == 0,
                      let boundsDict = window[kCGWindowBounds as String] as? [String: CGFloat],
                      let id = window[kCGWindowNumber as String] as? Int else { continue }
                let app = window[kCGWindowOwnerName as String] as? String ?? "?"
                if let filter, !app.lowercased().contains(filter) { continue }
                let title = window[kCGWindowName as String] as? String ?? ""
                let rect = CGRect(
                    x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                    width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
                )
                guard rect.width > 0, rect.height > 0 else { continue }
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let index = ScreenGeometry.displayIndex(for: center, screens: screens)
                let display = index.map { screens[$0] }
                var line = "id=\(id) \(app)"
                if !title.isEmpty { line += " «\(title)»" }
                line += " x=\(Int(rect.minX)) y=\(Int(rect.minY)) w=\(Int(rect.width)) h=\(Int(rect.height))"
                if let display {
                    let pixel = ScreenGeometry.pixels(fromPoint: CGPoint(x: rect.minX, y: rect.minY), in: display)
                    line += " display=\(index!) scale=\(Int(display.scale)) px=\(Int(pixel.x)),\(Int(pixel.y))"
                } else {
                    line += " display=?"
                }
                lines.append(line)
            }
            return .ok(lines.isEmpty
                ? "Окон не найдено."
                : "\(lines.count) окон:\n" + lines.joined(separator: "\n"))

        case "apps":
            let filter = (args["filter"] as? String)?.lowercased()
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .filter { filter == nil || ($0.localizedName ?? "").lowercased().contains(filter!) }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            let lines = apps.map { app in
                let front = app.isActive ? " frontmost" : ""
                return "\(app.localizedName ?? "?") bundle=\(app.bundleIdentifier ?? "-") "
                    + "pid=\(app.processIdentifier)\(front)"
            }
            return .ok(lines.isEmpty ? "Приложений не найдено." : lines.joined(separator: "\n"))

        default:
            return .fail("action: list | apps")
        }
    }

    /// Displays in the same global point space as `kCGWindowBounds`.
    static func displays() -> [DisplaySpace] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let pixelWidth = CGDisplayPixelsWide(id)
            let scale = bounds.width > 0 ? CGFloat(pixelWidth) / bounds.width : 1
            return DisplaySpace(
                origin: bounds.origin,
                size: bounds.size,
                scale: scale
            )
        }
    }
}
