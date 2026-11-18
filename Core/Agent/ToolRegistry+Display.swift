import AppKit
import CoreGraphics
import Foundation

extension ToolRegistry {
    /// R25.2: displays are read as data and changed as transactions. Every change saves
    /// the previous layout, so a bad mode is one `restore_last` away.
    func displayTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "list"
        switch action {
        case "list":
            let entries = DisplayControl.entries()
            guard !entries.isEmpty else { return .ok("Дисплеев не найдено.") }
            let lines = entries.enumerated().map { index, entry -> String in
                var line = "\(index) id=\(entry.id) \(entry.name)"
                if let mode = entry.mode {
                    line += " mode=\(mode.width)×\(mode.height)@\(Int(mode.refresh))"
                }
                line += " origin=\(Int(entry.originX)),\(Int(entry.originY))"
                line += " scale=\(Int(DisplayControl.scale(of: entry.id)))"
                if entry.main { line += " main" }
                if entry.mirrored { line += " mirrored" }
                let modes = Set(DisplayControl.modes(of: entry.id).map {
                    "\($0.width)×\($0.height)"
                }).sorted()
                line += "\n    modes: " + modes.joined(separator: ", ")
                return line
            }
            return .ok(lines.joined(separator: "\n"))

        case "set_mode":
            guard let index = Self.int(args, "display") else {
                return .fail("set_mode: display обязателен (индекс из display list).")
            }
            guard let width = Self.int(args, "width"), let height = Self.int(args, "height"),
                  width > 0, height > 0 else {
                return .fail("set_mode: width и height обязательны.")
            }
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("set_mode требует confirm: true: неудачный режим — это «нет сигнала» "
                    + "на живом мониторе. Прежняя раскладка сохранена в backups/display.json.")
            }
            guard let id = DisplayControl.displayID(at: index) else {
                return .fail("Нет дисплея \(index).")
            }
            let refresh = (args["refresh"] as? Double) ?? Double(Self.int(args, "refresh") ?? 0)
            guard let chosen = DisplayChooser.pick(
                DisplayControl.modes(of: id), width: width, height: height,
                refresh: refresh > 0 ? refresh : nil
            ) else {
                return .fail("Режим \(width)×\(height) недоступен на дисплее \(index).")
            }
            DisplayLayoutStore.save(DisplayControl.layout())
            guard DisplayControl.apply(mode: (id, chosen)) else {
                return .fail("CGConfigureDisplayWithDisplayMode отказал. Верни прежний режим: "
                    + "display restore_last.")
            }
            return .ok("Дисплей \(index): \(chosen.width)×\(chosen.height)@\(Int(chosen.refresh)).")

        case "arrangement":
            guard let index = Self.int(args, "display"),
                  let x = Self.int(args, "x"), let y = Self.int(args, "y") else {
                return .fail("arrangement: display, x и y обязательны.")
            }
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("arrangement требует confirm: true: окна и курсор уедут на другой экран.")
            }
            guard let id = DisplayControl.displayID(at: index) else {
                return .fail("Нет дисплея \(index).")
            }
            DisplayLayoutStore.save(DisplayControl.layout())
            guard DisplayControl.apply(origin: (id, CGPoint(x: x, y: y))) else {
                return .fail("CGConfigureDisplayOrigin отказал.")
            }
            return .ok("Дисплей \(index) перемещён в \(x),\(y) точек.")

        case "mirror":
            guard let index = Self.int(args, "display") else {
                return .fail("mirror: display обязателен.")
            }
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("mirror требует confirm: true.")
            }
            guard let id = DisplayControl.displayID(at: index) else {
                return .fail("Нет дисплея \(index).")
            }
            let on = Self.bool(args, "value") ?? true
            let master: CGDirectDisplayID
            if on {
                let masterIndex = Self.int(args, "master") ?? 0
                guard let found = DisplayControl.displayID(at: masterIndex) else {
                    return .fail("Нет дисплея \(masterIndex) для master.")
                }
                master = found
            } else {
                master = CGMainDisplayID()
            }
            DisplayLayoutStore.save(DisplayControl.layout())
            guard DisplayControl.apply(mirror: (id, on ? master : kCGNullDirectDisplay)) else {
                return .fail("CGConfigureDisplayMirrorOfDisplay отказал.")
            }
            return .ok("Дисплей \(index): зеркало \(on ? "на дисплей \(Self.int(args, "master") ?? 0)" : "выключено").")

        case "rotate":
            guard let index = Self.int(args, "display") else {
                return .fail("rotate: display обязателен.")
            }
            guard let degrees = Self.int(args, "degrees") else {
                return .fail("rotate: degrees обязателен (0, 90, 180, 270).")
            }
            guard [0, 90, 180, 270].contains(degrees) else {
                return .fail("rotate: degrees 0 | 90 | 180 | 270.")
            }
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("rotate требует confirm: true: экран уйдёт в поворот.")
            }
            guard let id = DisplayControl.displayID(at: index) else {
                return .fail("Нет дисплея \(index).")
            }
            DisplayLayoutStore.save(DisplayControl.layout())
            guard let rotated = DisplayControl.rotate(id, degrees: Double(degrees)) else {
                return .fail("unsupported: CGSConfigureDisplayRotation не найден. Поворот не изменён.")
            }
            return rotated
                ? .ok("Дисплей \(index) повёрнут на \(degrees)°.")
                : .fail("Поворот отказал на уровне системы.")

        case "night_shift":
            let value = args["value"]
            if let strength = value as? Double ?? (value as? Int).map(Double.init) {
                let level = Float(max(0, min(100, strength))) / 100
                guard let ok = NightShift.setStrength(level) else {
                    return .fail("unsupported: CBBlueLightClient без сеттера strength "
                        + "(setStrength:commit: недоступен из Swift без C-шимa). "
                        + "Силу не меняю, чтобы не соврать.")
                }
                return ok ? .ok("Night Shift strength=\(Int(level * 100))%.")
                    : .fail("Night Shift strength не изменился.")
            }
            let on: Bool
            if let flag = Self.bool(args, "value") ?? Self.bool(args, "on") {
                on = flag
            } else {
                return .fail("night_shift: value on | off | 0..100.")
            }
            guard let ok = NightShift.setEnabled(on) else {
                return .fail("unsupported: CBBlueLightClient.setEnabled: не найден.")
            }
            return ok ? .ok("Night Shift \(on ? "включён" : "выключен").")
                : .fail("Night Shift не переключился.")

        case "restore_last":
            guard let saved = DisplayLayoutStore.load() else {
                return .fail("Нет сохранённой раскладки в backups/display.json.")
            }
            var restored: [String] = []
            var failed: [String] = []
            for entry in saved.displays {
                guard let mode = entry.mode else { continue }
                if DisplayControl.apply(mode: (entry.id, mode)) {
                    restored.append("id=\(entry.id) \(mode.width)×\(mode.height)")
                } else {
                    failed.append("id=\(entry.id)")
                }
            }
            let head = restored.isEmpty
                ? "Раскладка не восстановлена."
                : "Восстановлено: " + restored.joined(separator: ", ")
            return .ok(head + (failed.isEmpty ? "" : "\nНе удалось: " + failed.joined(separator: ", ")))

        default:
            return .fail("action: list | set_mode | arrangement | mirror | rotate | night_shift | restore_last")
        }
    }
}
