import AppKit

extension ToolRegistry {
    /// R18.6/R25.8: list, open, activate, hide and quit applications and files.
    func appsTool(_ args: [String: Any]) -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "list"
        switch action {
        case "list":
            let apps = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular }
                .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
            return .ok(apps.map {
                "\($0.localizedName ?? "?") bundle=\($0.bundleIdentifier ?? "-") "
                    + "pid=\($0.processIdentifier)\($0.isActive ? " frontmost" : "")"
            }.joined(separator: "\n"))
        case "open":
            guard let target = (args["target"] as? String) ?? (args["path"] as? String) else {
                return .fail("target или path обязателен")
            }
            let remote = URL(string: target).flatMap { url -> URL? in
                guard let scheme = url.scheme, scheme != "file" else { return nil }
                return url
            }
            let url = remote ?? resolve(target)
            guard FileManager.default.fileExists(atPath: url.path) || remote != nil else {
                return .fail("Не найдено: \(display(url))")
            }
            return NSWorkspace.shared.open(url) ? .ok("Открыто: \(url.absoluteString)") : .fail("Не удалось открыть.")
        case "activate", "hide", "quit":
            guard let app = Self.application(args) else { return .fail("Приложение не найдено.") }
            switch action {
            case "activate": return app.activate() ? .ok("Активировано.") : .fail("Не удалось активировать.")
            case "hide": return app.hide() ? .ok("Скрыто.") : .fail("Не удалось скрыть.")
            default:
                guard Self.bool(args, "confirm") ?? false else {
                    return .fail("quit требует confirm: true: это завершает чужую работу.")
                }
                return app.terminate() ? .ok("Запрошено завершение.") : .fail("Не удалось завершить.")
            }
        default:
            return .fail("action: list | open | activate | hide | quit")
        }
    }

    static func application(_ args: [String: Any]) -> NSRunningApplication? {
        if let pid = int(args, "pid") { return NSRunningApplication(processIdentifier: pid_t(pid)) }
        guard let query = (args["app"] as? String)?.lowercased(), !query.isEmpty else { return nil }
        return NSWorkspace.shared.runningApplications.first {
            ($0.localizedName ?? "").lowercased().contains(query)
                || ($0.bundleIdentifier ?? "").lowercased().contains(query)
        }
    }
}
