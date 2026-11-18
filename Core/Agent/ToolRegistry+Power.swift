import AppKit
import CoreAudio
import Foundation

extension ToolRegistry {
    /// R25.1: power, brightness, sound, media. Mutations run; read-only mode keeps the
    /// status and device list.
    func powerTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "status"
        guard PowerGuard.actions.contains(action) else {
            return .fail("action: " + PowerGuard.actions.sorted().joined(separator: " | "))
        }
        let mutating = action != "status" && !(action == "audio" && args["device"] == nil)
        if readOnly, mutating {
            return .fail("power \(action) недоступен: активен режим только-чтение.")
        }

        switch action {
        case "status":
            var text = SystemReport.text(sections: ["power"])
            text += "\nassertions=\(PowerAssertions.count)"
            return .ok(text)

        case "sleep":
            return await runPowerCommand("pmset sleepnow", success: "Ухожу в сон.")

        case "display_off":
            return await runPowerCommand("pmset displaysleepnow", success: "Экран выключен.")

        case "lock":
            guard let raw = PrivateSymbols.load("SACLockScreenImmediate", from: PowerFrameworks.login) else {
                return .fail("unsupported: SACLockScreenImmediate не найден в login.framework. "
                    + "Экран не заблокирован; пароль не вводится и обход блокировки не делается.")
            }
            typealias Lock = @convention(c) () -> Int32
            let lock = unsafeBitCast(raw, to: Lock.self)
            return lock() == 0
                ? .ok("Экран заблокирован (SACLockScreenImmediate).")
                : .fail("SACLockScreenImmediate вернул ошибку; экран не заблокирован.")

        case "caffeinate":
            if Self.bool(args, "off") ?? false {
                let released = PowerAssertions.releaseAll()
                return .ok("Снято ассершенов: \(released).")
            }
            let seconds = min(max(Self.int(args, "seconds") ?? 300, 1), 3_600)
            guard PowerAssertions.hold(seconds: seconds) else {
                return .fail("IOPMAssertionCreateWithName отказал: сон не удерживается.")
            }
            return .ok("Держу Мак активным \(seconds) с (ассершенов: \(PowerAssertions.count)). "
                + "Проверить: pmset -g assertions.")

        case "low_power":
            guard let value = Self.int(args, "value"), value == 0 || value == 1 else {
                return .fail("low_power: value 0 или 1 обязателен.")
            }
            return await runPowerCommand(
                "pmset -a lowpowermode \(value)",
                success: "Режим низкого энергопотребления: \(value == 1 ? "вкл" : "выкл")."
            )

        case "brightness":
            guard let percent = PowerValue.percent(args["value"]) else {
                return .fail("brightness: value 0..100 обязателен.")
            }
            let displays = Self.displays()
            let index = Self.int(args, "display") ?? 0
            guard index >= 0, index < displays.count else {
                return .fail("Нет дисплея \(index); всего \(displays.count).")
            }
            let id = Self.displayID(at: index)
            guard DisplayBrightness.isAvailable, let id else {
                return .fail("unsupported: DisplayServicesGetBrightness/SetBrightness не найдены. "
                    + "Яркость не изменена.")
            }
            guard DisplayBrightness.set(percent, on: id) else {
                return .fail("DisplayServicesSetBrightness отказал для дисплея \(index).")
            }
            let actual = DisplayBrightness.brightness(of: id).map(String.init) ?? "?"
            return .ok("Яркость дисплея \(index): \(actual)% (просили \(percent)).")

        case "volume":
            guard let percent = PowerValue.percent(args["value"]) else {
                return .fail("volume: value 0..100 обязателен.")
            }
            guard let device = Self.audioDevice(args, output: true) else {
                return .fail("Устройство вывода не найдено. Список: power audio.")
            }
            guard AudioHAL.setVolume(percent, of: device.id) else {
                return .fail("Громкость на «\(device.name)» не выставляется (нет свойства).")
            }
            let actual = AudioHAL.volume(of: device.id).map(String.init) ?? "?"
            return .ok("Громкость «\(device.name)»: \(actual)% (просили \(percent)).")

        case "mute":
            let want = Self.bool(args, "value") ?? true
            let input = Self.bool(args, "input") ?? false
            guard let device = Self.audioDevice(args, output: !input) else {
                return .fail("Устройство \(input ? "ввода" : "вывода") не найдено.")
            }
            let scope = input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput
            guard AudioHAL.setMuted(want, of: device.id, scope: scope) else {
                return .fail("Mute не выставляется на «\(device.name)».")
            }
            let actual = AudioHAL.isMuted(device.id, scope: scope).map { $0 ? "on" : "off" } ?? "?"
            return .ok("Mute \(input ? "микрофона" : "вывода") «\(device.name)»: \(actual).")

        case "media":
            let command = (args["value"] as? String)?.lowercased() ?? "toggle"
            guard MediaRemote.commands[command] != nil else {
                return .fail("media: value play | pause | toggle | next | previous.")
            }
            guard let sent = MediaRemote.send(command) else {
                return .fail("unsupported: MRMediaRemoteSendCommand не найден в MediaRemote.framework. "
                    + "Медиа-клавиша не нажималась.")
            }
            return sent
                ? .ok("Медиа-команда отправлена: \(command).")
                : .fail("MRMediaRemoteSendCommand отказал для \(command).")

        case "audio":
            if let wanted = args["device"] as? String {
                let output = (args["direction"] as? String)?.lowercased() != "input"
                guard let device = Self.audioDevice(args, output: output) else {
                    return .fail("Устройство «\(wanted)» не найдено. Список: power audio.")
                }
                guard AudioHAL.setDefault(device.id, output: output) else {
                    return .fail("Не удалось переключить \(output ? "вывод" : "ввод") на «\(device.name)».")
                }
                return .ok("\(output ? "Вывод" : "Ввод") по умолчанию: «\(device.name)».")
            }
            let devices = AudioHAL.devices()
            guard !devices.isEmpty else { return .ok("Аудиоустройств не найдено.") }
            let lines = devices.map { device -> String in
                var line = "\(device.name) id=\(device.id)"
                if device.hasOutput { line += " out" }
                if device.hasInput { line += " in" }
                if device.isDefaultOutput { line += " default-out" }
                if device.isDefaultInput { line += " default-in" }
                if device.hasOutput, let volume = AudioHAL.volume(of: device.id) {
                    line += " volume=\(volume)%"
                }
                return line
            }
            return .ok(lines.joined(separator: "\n"))

        case "restart", "shutdown":
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("\(action) требует confirm: true — это выключает Мак.")
            }
            let risky = UnsavedDocuments.riskyApps()
            if !risky.isEmpty {
                return .fail("Отказ: есть несохранённые документы (\(risky.joined(separator: ", "))). "
                    + "Диалог «сохранить?» повесит выключение. Сохрани или закрой их и повтори.")
            }
            let event = action == "restart" ? "aevtrrst" : "aevtrsdn"
            let script = "tell application \"loginwindow\" to «event \(event)»"
            let command = "osascript -e \(Self.shellQuote(script))"
            do {
                let output = try Self.runSync(command, cwd: workspace, timeout: 20)
                let (status, body) = Self.splitExit(output)
                guard status == 0 else {
                    let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
                    return .fail("\(action) не выполнен (exit \(status)): \(detail). "
                        + "Нужен грант Automation для loginwindow или ручное подтверждение.")
                }
                return .ok("Команда \(action) отправлена loginwindow.")
            } catch {
                return .fail(error.localizedDescription)
            }

        default:
            return .fail("action неизвестен")
        }
    }

    private func runPowerCommand(_ command: String, success: String) async -> ToolResult {
        do {
            let output = try Self.runSync(command, cwd: workspace, timeout: 30)
            let (status, body) = Self.splitExit(output)
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard status == 0 else {
                return .fail("exit \(status): " + String(text.prefix(600)))
            }
            return .ok(success + (text.isEmpty ? "" : "\n" + text))
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    static func displayID(at index: Int) -> CGDirectDisplayID? {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        guard index >= 0, index < Int(count) else { return nil }
        return ids[index]
    }

    /// By id, by name substring, or the system default for that direction.
    static func audioDevice(_ args: [String: Any], output: Bool) -> AudioHAL.Device? {
        let devices = AudioHAL.devices()
        if let id = int(args, "id"), let match = devices.first(where: { $0.id == AudioDeviceID(id) }) {
            return match
        }
        if let name = (args["device"] as? String)?.lowercased(), !name.isEmpty {
            return devices.first { $0.name.lowercased().contains(name) }
        }
        return devices.first { output ? $0.isDefaultOutput : $0.isDefaultInput }
    }
}
