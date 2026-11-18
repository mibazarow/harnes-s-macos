import AppKit
import Foundation

extension ToolRegistry {
    /// R25.10: shell and appearance. Mutations read their value back; a theme that did
    /// not stick is reported as not applied, not as done.
    func settingsTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "appearance"
        switch action {
        case "appearance":
            guard let choice = AppearanceChoice.parse(args["value"] as? String) else {
                return .fail("appearance: value dark | light | auto.")
            }
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("appearance требует confirm: true: тема меняет весь интерфейс.")
            }
            guard let output = try? Self.runSync(
                choice.command, cwd: workspace, timeout: 10
            ) else { return .fail("defaults не выполнился.") }
            let (status, body) = Self.splitExit(output)
            if status != 0, choice != .light {
                return .fail("defaults: " + String(body.prefix(300)))
            }
            DistributedNotificationCenter.default.post(
                name: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
                object: nil, userInfo: nil
            )
            let actual = Self.readDefaults(domain: "-g", key: "AppleInterfaceStyle")
            let applied = choice.expected == actual
            var text = "appearance: \(choice.rawValue) (прочитано: \(actual ?? "light"))"
            if !applied {
                text += " — запись не подтвердилась. Приложения и Dock могут перекраситься "
                    + "только после перезапуска."
            }
            return .ok(text)

        case "wallpaper":
            guard let raw = args["path"] as? String, !raw.isEmpty else {
                return .fail("wallpaper: path или solid:#RRGGBB обязателен.")
            }
            var imageURL: URL
            if raw.lowercased().hasPrefix("solid:") {
                let hex = String(raw.dropFirst("solid:".count))
                guard let color = SolidColor.parse(hex) else {
                    return .fail("solid: нужен цвет #RRGGBB.")
                }
                try? AppPaths.ensureDirectory(AppPaths.artifactsDirectory)
                let url = AppPaths.artifactsDirectory
                    .appendingPathComponent("wallpaper-\(hex).png")
                let image = SolidColor.image(color)
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: .png, properties: [:]) else {
                    return .fail("Не удалось построить однотонную картинку.")
                }
                try? data.write(to: url)
                imageURL = url
            } else {
                imageURL = resolve(raw)
                guard FileManager.default.fileExists(atPath: imageURL.path) else {
                    return .fail("Файл обоев не найден: \(display(imageURL))")
                }
            }
            var applied: [String] = []
            for screen in NSScreen.screens {
                do {
                    try NSWorkspace.shared.setDesktopImageURL(imageURL, for: screen, options: [:])
                    applied.append(screen.localizedName ?? "display")
                } catch {
                    return .fail("Обои не установились на «\(screen.localizedName ?? "?")»: "
                        + error.localizedDescription)
                }
            }
            return .ok("Обои установлены на \(applied.count) экран(ов): "
                + applied.joined(separator: ", ") + " → \(imageURL.path)")

        case "dock":
            guard let knob = args["value"] as? String,
                  let setting = DockControl.write(knob, value: (args["setting"] as? String) ?? "") else {
                return .fail("dock: value autohide|position|size|magnification и setting.")
            }
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("dock требует confirm: true: Dock перезапустится.")
            }
            let command = "defaults write com.apple.dock \(setting.key) "
                + (setting.value == "true" || setting.value == "false"
                    ? "-bool \(setting.value)" : "-string \(Self.shellQuote(setting.value))")
            guard let output = try? Self.runSync(command + " && killall Dock", cwd: workspace, timeout: 20) else {
                return .fail("defaults/killall не выполнились.")
            }
            let (status, body) = Self.splitExit(output)
            guard status == 0 else {
                return .fail("exit \(status): " + String(body.prefix(300)))
            }
            let actual = Self.readDefaults(domain: "com.apple.dock", key: setting.key)
            return .ok("Dock \(knob)=\(setting.value) (прочитано: \(actual ?? "?")).")

        case "menu_bar":
            guard let on = Self.bool(args, "value") else {
                return .fail("menu_bar: value on/off.")
            }
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("menu_bar требует confirm: true.")
            }
            let command = "defaults write NSGlobalDomain _HIHideMenuBar -bool \(on ? "true" : "false") "
                + "&& killall SystemUIServer"
            guard let output = try? Self.runSync(command, cwd: workspace, timeout: 20) else {
                return .fail("defaults не выполнился.")
            }
            let (status, _) = Self.splitExit(output)
            return status == 0
                ? .ok("Строка меню: \(on ? "скрыта" : "показана").")
                : .fail("Строка меню не переключилась (exit \(status)).")

        case "hot_corners":
            guard let corner = args["value"] as? String,
                  let key = HotCorner.key(corner: corner),
                  let modifier = HotCorner.modifierKey(corner: corner) else {
                return .fail("hot_corners: value top-left|top-right|bottom-left|bottom-right.")
            }
            let actionName = ((args["setting"] as? String) ?? "none").lowercased()
            guard let code = HotCorner.actions[actionName] else {
                return .fail("hot_corners: setting " + HotCorner.actions.keys.sorted().joined(separator: " | "))
            }
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("hot_corners требует confirm: true.")
            }
            let command = "defaults write com.apple.dock \(key) -int \(code) "
                + "&& defaults write com.apple.dock \(modifier) -int 0 && killall Dock"
            guard let output = try? Self.runSync(command, cwd: workspace, timeout: 20) else {
                return .fail("defaults не выполнился.")
            }
            let (status, _) = Self.splitExit(output)
            return status == 0
                ? .ok("Угол \(corner): \(actionName).")
                : .fail("Угол не записался (exit \(status)).")

        case "focus":
            let on = Self.bool(args, "value") ?? true
            let name = (args["shortcut"] as? String) ?? "Set Focus"
            guard let output = try? Self.runSync(
                "shortcuts list", cwd: workspace, timeout: 15
            ) else {
                return .fail("shortcuts не ответил.")
            }
            let (status, body) = Self.splitExit(output)
            guard status == 0 else {
                return .fail("shortcuts: " + String(body.prefix(300)))
            }
            let names = body.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard names.contains(where: { $0 == name }) else {
                return .fail("unsupported: шортката «\(name)» нет. Создай в Shortcuts шорткат "
                    + "Set Focus (on/off) и передай его имя в shortcut.")
            }
            guard let run = try? Self.runSync(
                "shortcuts run \(Self.shellQuote(name))", cwd: workspace, timeout: 30
            ) else { return .fail("shortcuts run не выполнился.") }
            let (runStatus, runBody) = Self.splitExit(run)
            return runStatus == 0
                ? .ok("Focus \(on ? "включён" : "выключен") через «\(name)».")
                : .fail("shortcuts run: " + String(runBody.prefix(300)))

        case "screensaver":
            guard let output = try? Self.runSync(
                "open -a ScreenSaverEngine", cwd: workspace, timeout: 15
            ) else { return .fail("open не выполнился.") }
            let (status, body) = Self.splitExit(output)
            return status == 0
                ? .ok("Скринсейвер запущен.")
                : .fail("Скринсейвер не запустился: " + String(body.prefix(300)))

        case "accessibility":
            guard let knob = (args["value"] as? String)?.lowercased() else {
                return .fail("accessibility: value invert|zoom|cursor.")
            }
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("accessibility требует confirm: true: это меняет вид экрана. "
                    + "Вернуть назад: тот же вызов с setting=off.")
            }
            let on = Self.bool(args, "setting") ?? Self.bool(args, "on") ?? true
            let command: String
            switch knob {
            case "invert":
                command = "defaults write com.apple.universalaccess whiteOnBlack "
                    + "-bool \(on ? "true" : "false")"
            case "zoom":
                command = "defaults write com.apple.universalaccess closeViewZoomFollowsFocus "
                    + "-bool \(on ? "true" : "false")"
            case "cursor":
                let size = min(max(Self.int(args, "size") ?? 2, 1), 4)
                command = "defaults write com.apple.universalaccess cursorScale -float \(size)"
            default:
                return .fail("accessibility: value invert|zoom|cursor.")
            }
            guard let output = try? Self.runSync(command, cwd: workspace, timeout: 10) else {
                return .fail("defaults не выполнился.")
            }
            let (status, _) = Self.splitExit(output)
            return status == 0
                ? .ok("accessibility \(knob): \(on ? "on" : "off"). Не забудь вернуть назад в конце хода.")
                : .fail("Настройка доступности не записалась (exit \(status)).")

        default:
            return .fail("action: appearance | wallpaper | dock | menu_bar | hot_corners | focus | screensaver | accessibility")
        }
    }

    static func readDefaults(domain: String, key: String) -> String? {
        guard let output = try? runSync(
            "defaults read \(domain) \(key)", cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 10
        ) else { return nil }
        let (status, body) = splitExit(output)
        guard status == 0 else { return nil }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
