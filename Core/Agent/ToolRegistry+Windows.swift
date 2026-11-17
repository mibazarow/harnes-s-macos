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

        case "move", "resize", "minimize", "close", "fullscreen", "to_display":
            guard InputAccess.isTrusted else { return .fail(InputAccess.refusal) }
            guard let id = Self.int(args, "id") else { return .fail("id обязателен") }
            guard let (element, _) = WindowActions.element(for: id) else {
                return .fail("Окно \(id) не найдено в AX. Список — windows list.")
            }
            switch action {
            case "move":
                guard let x = Self.int(args, "x"), let y = Self.int(args, "y") else {
                    return .fail("move: x и y обязательны")
                }
                return WindowActions.setFrame(element, position: CGPoint(x: x, y: y))
                    ? .ok("Окно \(id) перемещено в \(x),\(y).")
                    : .fail("AX отказал в перемещении окна \(id).")
            case "resize":
                guard let w = Self.int(args, "w"), let h = Self.int(args, "h"), w > 100, h > 100 else {
                    return .fail("resize: w и h обязательны, минимум 100")
                }
                return WindowActions.setFrame(element, size: CGSize(width: w, height: h))
                    ? .ok("Окно \(id): \(w)×\(h).")
                    : .fail("AX отказал в изменении размера окна \(id).")
            case "minimize":
                let status = AXUIElementSetAttributeValue(
                    element, kAXMinimizedAttribute as CFString, kCFBooleanTrue
                )
                return status == .success ? .ok("Окно \(id) свёрнуто.") : .fail("AX отказал.")
            case "fullscreen":
                let on = Self.bool(args, "value") ?? true
                let value: CFTypeRef = on ? (kCFBooleanTrue as CFBoolean) : (kCFBooleanFalse as CFBoolean)
                let status = AXUIElementSetAttributeValue(
                    element, "AXFullScreen" as CFString, value
                )
                return status == .success ? .ok("Полный экран переключён.") : .fail("AX отказал.")
            case "close":
                return WindowActions.press(element, attribute: kAXCloseButtonAttribute as String)
                    ? .ok("Окно \(id) закрыто.")
                    : .fail("Кнопка закрытия недоступна; не продавливаю.")
            default:
                guard let target = Self.int(args, "display") else {
                    return .fail("to_display: display обязателен (индекс из windows list)")
                }
                let displays = Self.displays()
                guard target >= 0, target < displays.count else {
                    return .fail("Нет дисплея \(target); всего \(displays.count).")
                }
                guard let frame = AXBridge.frame(element) else { return .fail("У окна нет рамки.") }
                let size = WindowActions.fitted(size: frame.1, into: displays[target])
                let origin = WindowActions.origin(for: size, in: displays[target])
                return WindowActions.setFrame(element, position: origin, size: size)
                    ? .ok("Окно \(id) перенесено на дисплей \(target).")
                    : .fail("AX отказал в переносе.")
            }

        default:
            return .fail("action: list | apps | move | resize | minimize | close | fullscreen | to_display")
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
