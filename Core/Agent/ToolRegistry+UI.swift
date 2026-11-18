import AppKit
import ApplicationServices
import CoreGraphics

extension ToolRegistry {
    /// R18.2: read the AX tree and act on an element by path. Paths come from `tree` or
    /// `find`, so the model never has to guess coordinates.
    func uiTool(_ args: [String: Any]) -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "tree"
        guard let pid = Self.applicationPID(args) else {
            return .fail("Приложение не найдено. Передай app (имя или bundle id) или pid.")
        }
        guard InputAccess.isTrusted else { return .fail(InputAccess.refusal) }

        let root = AXUIElementCreateApplication(pid)
        switch action {
        case "tree":
            var budget = min(max(Self.int(args, "max_nodes") ?? 2_000, 50), 20_000)
            let maxDepth = min(max(Self.int(args, "depth") ?? 3, 1), 8)
            let node = AXBridge.snapshot(root, depth: 0, budget: &budget)
            var linesBudget = maxDepth * 0 + 100_000
            let lines = node.lines(depth: 0, maxNodes: budget, budget: &linesBudget)
            return .ok("pid=\(pid) узлов≈\(lines.count)\n" + lines.joined(separator: "\n"))
        case "find":
            if let image = args["image"] as? String {
                return pixelFind(image: image, args: args, pid: pid)
            }
            guard let query = args["query"] as? String, !query.isEmpty else {
                return .fail("query обязателен (или image для поиска по шаблону)")
            }
            var budget = 8_000
            let node = AXBridge.snapshot(root, depth: 0, budget: &budget)
            var searchBudget = 8_000
            let limit = min(max(Self.int(args, "limit") ?? 20, 1), 100)
            let found = node.search(
                query, regex: Self.bool(args, "regex") ?? false,
                limit: limit, budget: &searchBudget
            )
            guard !found.isEmpty else { return .ok("ax: empty — ничего не найдено по «\(query)».") }
            return .ok(found.map { node in
                var line = "\(node.path.description) \(node.role)"
                if !node.title.isEmpty { line += " «\(node.title)»" }
                if let center = node.center {
                    line += " center=\(Int(center.x)),\(Int(center.y))"
                }
                if !node.enabled { line += " disabled" }
                return line
            }.joined(separator: "\n"))
        case "click":
            if let image = args["image"] as? String {
                return pixelClick(image: image, args: args, pid: pid)
            }
            guard let path = Self.path(args), let element = AXBridge.element(at: path, in: root) else {
                return .fail("path не найден; сначала вызови ui tree или find.")
            }
            let verify = Self.bool(args, "verify") ?? false
            var beforeFrame: CGRect?
            if verify, let frame = AXBridge.frame(element) {
                beforeFrame = CGRect(origin: frame.0, size: frame.1)
            }
            if AXUIElementPerformAction(element, kAXPressAction as CFString) == .success {
                return .ok("Нажато: \(path.description)" + Self.verification(beforeFrame))
            }
            guard let frame = AXBridge.frame(element) else {
                return .fail("Элемент не поддерживает press и не имеет координат.")
            }
            let center = CGPoint(x: frame.0.x + frame.1.width / 2, y: frame.0.y + frame.1.height / 2)
            Self.click(at: center)
            return .ok("Press не поддерживается; клик по центру \(Int(center.x)),\(Int(center.y))."
                + Self.verification(beforeFrame))
        case "set_value":
            guard let path = Self.path(args), let element = AXBridge.element(at: path, in: root) else {
                return .fail("path не найден.")
            }
            guard let value = args["value"] as? String else { return .fail("value обязателен") }
            let status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, value as CFString)
            return status == .success ? .ok("Значение установлено.") : .fail("AX отказал (код \(status.rawValue)).")
        case "menu_list":
            guard let bar = AXBridge.attribute(root, kAXMenuBarAttribute) else {
                return .fail("У приложения нет строки меню.")
            }
            let node = MenuBridge.snapshot(bar as! AXUIElement)
            return .ok(node.listed().joined(separator: "\n"))
        case "menu_click":
            guard let wanted = args["path_titles"] as? [String], !wanted.isEmpty else {
                return .fail("path_titles обязателен: список пунктов, например [\"File\",\"Export\",\"PDF\"]")
            }
            guard let bar = AXBridge.attribute(root, kAXMenuBarAttribute) else {
                return .fail("У приложения нет строки меню.")
            }
            guard let element = Self.menuElement(bar as! AXUIElement, path: wanted) else {
                return .fail("Пункт меню не найден: \(wanted.joined(separator: " > ")).")
            }
            let status = AXUIElementPerformAction(element, kAXPressAction as CFString)
            return status == .success
                ? .ok("Нажато: \(wanted.joined(separator: " > ")).")
                : .fail("AX отказал в нажатии (код \(status.rawValue)).")
        case "focus":
            guard let path = Self.path(args), let element = AXBridge.element(at: path, in: root) else {
                return .fail("path не найден.")
            }
            NSRunningApplication(processIdentifier: pid)?.activate()
            let status = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            return status == .success ? .ok("Фокус передан.") : .fail("AX отказал (код \(status.rawValue)).")
        default:
            return .fail("action: tree | find | click | set_value | focus | menu_list | menu_click")
        }
    }

    static func applicationPID(_ args: [String: Any]) -> pid_t? {
        if let pid = int(args, "pid") { return pid_t(pid) }
        let apps = NSWorkspace.shared.runningApplications
        if let query = (args["app"] as? String)?.lowercased(), !query.isEmpty {
            return apps.first {
                ($0.localizedName ?? "").lowercased().contains(query)
                    || ($0.bundleIdentifier ?? "").lowercased().contains(query)
            }?.processIdentifier
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier
    }

    static func path(_ args: [String: Any]) -> [Int]? {
        guard let raw = args["path"] as? [Any] else { return nil }
        let values = raw.compactMap { value -> Int? in
            if let number = value as? Int { return number }
            if let number = value as? Double { return Int(number) }
            return nil
        }
        return values.count == raw.count ? values : nil
    }

    static func click(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}


extension ToolRegistry {
    static func menuElement(_ root: AXUIElement, path: [String]) -> AXUIElement? {
        var current = root
        for title in path {
            let match = AXBridge.children(current).first { child in
                AXBridge.string(child, kAXTitleAttribute)
                    .compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            guard let match else { return nil }
            current = match
        }
        return current
    }
}


extension ToolRegistry {
    static func verification(_ rect: CGRect?) -> String {
        guard let rect else { return "" }
        guard CGPreflightScreenCaptureAccess() else {
            return "\nverify: нет гранта Screen Recording, сравнение кадров пропущено."
        }
        guard let (changed, before, after) = ScreenshotVerify.captureAndCompare(rect: rect) else {
            return "\nverify: кадры не сняты."
        }
        return "\nverify: changed=\(changed) before=\(before) after=\(after)"
    }
}

/// R18.10: the pixel fallback. AX is the primary path; this exists for canvas, WebGL,
/// games and Metal views where the tree is empty. Coordinates are converted to screen
/// points, an ambiguous template is refused, and a click proves itself with a
/// before/after frame instead of claiming success.
extension ToolRegistry {
    struct PixelRegion {
        let rect: CGRect
        let scale: CGFloat
    }

    static func pixelRegion(_ args: [String: Any], pid: pid_t) -> PixelRegion? {
        let rect: CGRect?
        if let id = int(args, "window_id") {
            rect = windowBounds(id: id)
        } else {
            rect = appWindowBounds(pid: pid)
        }
        guard let rect, rect.width >= 4, rect.height >= 4 else { return nil }
        let screens = displays()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let scale = ScreenGeometry.displayIndex(for: center, screens: screens)
            .map { screens[$0].scale } ?? 1
        return PixelRegion(rect: rect, scale: scale)
    }

    static func windowBounds(id: Int) -> CGRect? {
        let raw = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow], CGWindowID(id)
        ) as? [[String: Any]] ?? []
        return raw.compactMap(windowRect).first
    }

    static func appWindowBounds(pid: pid_t) -> CGRect? {
        let raw = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let own = raw.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == pid
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        return own.compactMap(windowRect)
            .filter { $0.width > 4 && $0.height > 4 }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    private static func windowRect(_ window: [String: Any]) -> CGRect? {
        guard let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
        return CGRect(
            x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
            width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0
        )
    }

    /// Template hits in screen points, with the capture's own scale measured from the
    /// file rather than assumed: `screencapture` decides the backing size.
    private func templateHits(image: String, args: [String: Any], pid: pid_t)
        -> (matches: [PixelMatch], scale: CGFloat, origin: CGPoint, capture: URL)? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        let templateURL = resolve(image)
        guard let templateImage = NSImage(contentsOf: templateURL),
              let template = templateImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        guard let region = Self.pixelRegion(args, pid: pid) else { return nil }
        guard let capture = ScreenshotVerify.capture(rect: region.rect, tag: "pixel"),
              let shot = NSImage(contentsOf: capture),
              let source = shot.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let scale = region.rect.width > 0 ? CGFloat(source.width) / region.rect.width : region.scale
        let threshold = (args["threshold"] as? Double) ?? PixelMatchPolicy.threshold
        let limit = min(max(Self.int(args, "limit") ?? PixelMatchPolicy.maxCandidates, 1), 10)
        let matches = TemplateMatcher.matches(
            in: source, template: template, threshold: threshold, limit: limit
        )
        return (matches, scale, region.rect.origin, capture)
    }

    func pixelFind(image: String, args: [String: Any], pid: pid_t) -> ToolResult {
        guard FileManager.default.fileExists(atPath: resolve(image).path) else {
            return .fail("Файл шаблона не найден: \(image)")
        }
        guard let found = templateHits(image: image, args: args, pid: pid) else {
            return .fail("Не удалось снять область окна: нужен грант Screen Recording "
                + "и видимое окно приложения (или window_id).")
        }
        guard !found.matches.isEmpty else {
            return .ok("pixel: empty — шаблон не найден (порог \(PixelMatchPolicy.threshold)).")
        }
        let lines = found.matches.map { match -> String in
            let point = ScreenGeometry.point(
                fromRegionPixels: match.center, origin: found.origin, scale: found.scale
            )
            return String(
                format: "score=%.3f center=%.0f,%.0f px=%.0f,%.0f size=%d×%d",
                match.score, point.x, point.y, match.center.x, match.center.y,
                match.width, match.height
            )
        }
        let head = PixelMatchPolicy.isAmbiguous(found.matches)
            ? "ambiguous: true — кандидаты слишком близки, не нажимай наугад."
            : "ambiguous: false"
        return .ok("\(head)\n" + lines.joined(separator: "\n"))
    }

    func pixelClick(image: String, args: [String: Any], pid: pid_t) -> ToolResult {
        guard let found = templateHits(image: image, args: args, pid: pid) else {
            return .fail("Не удалось снять область окна: нужен грант Screen Recording "
                + "и видимое окно приложения (или window_id).")
        }
        guard !found.matches.isEmpty else { return .fail("Шаблон не найден на экране.") }
        if PixelMatchPolicy.isAmbiguous(found.matches) {
            return .fail("ambiguous: два кандидата с близким score. "
                + "Уточни шаблон (уникальный фрагмент) и повтори.")
        }
        let match = found.matches[0]
        let point = ScreenGeometry.point(
            fromRegionPixels: match.center, origin: found.origin, scale: found.scale
        )
        let beforeData = try? Data(contentsOf: found.capture)
        Self.click(at: point)
        Thread.sleep(forTimeInterval: 0.35)
        guard let region = Self.pixelRegion(args, pid: pid),
              let afterURL = ScreenshotVerify.capture(rect: region.rect, tag: "pixel-after"),
              let afterData = try? Data(contentsOf: afterURL) else {
            return .ok(String(
                format: "Клик по шаблону: center=%.0f,%.0f score=%.3f; кадр после не снят.",
                point.x, point.y, match.score
            ))
        }
        Self.resampleIfNeeded(afterURL, scaleDown: nil, maxHeight: 720)
        let changed = beforeData.map { ScreenshotVerify.changed(before: $0, after: afterData) } ?? false
        return .ok(String(
            format: "Клик по шаблону: center=%.0f,%.0f score=%.3f changed=%@ shot=%@",
            point.x, point.y, match.score, changed ? "true" : "false", afterURL.path
        ))
    }
}
