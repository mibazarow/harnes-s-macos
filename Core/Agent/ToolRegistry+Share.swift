import AppKit
import Foundation

extension ToolRegistry {
    /// R26.3: compose opens a ready letter; send actually sends and therefore needs a
    /// confirmation; AirDrop returns "panel opened", not "sent".
    func shareTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "compose"
        switch action {
        case "services":
            let names = ShareControl.services()
            return .ok(names.isEmpty
                ? "Сервисов обмена не найдено."
                : names.joined(separator: "\n"))

        case "compose":
            let body = (args["body"] as? String) ?? ""
            guard !body.isEmpty else { return .fail("body обязателен") }
            let recipients = Self.stringList(args["to"])
            let subject = (args["subject"] as? String) ?? ""
            let attachments = Self.stringList(args["attachments"]).map(resolve)
            guard ShareControl.composeEmail(
                to: recipients, subject: subject, body: body, attachments: attachments
            ) else {
                return .fail("Сервис composeEmail недоступен: нет почтового клиента.")
            }
            return .ok("Письмо открыто для проверки: кому \(recipients.count), "
                + "вложений \(attachments.count). Отправляет человек.")

        case "send":
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("share send требует confirm: true: отправленное письмо не отменить.")
            }
            let recipients = Self.stringList(args["to"])
            guard !recipients.isEmpty else { return .fail("to обязателен: хотя бы один адрес.") }
            let body = (args["body"] as? String) ?? ""
            guard !body.isEmpty else { return .fail("body обязателен") }
            let subject = (args["subject"] as? String) ?? ""
            let script = ShareControl.emailScript(to: recipients, subject: subject, body: body)
            let command = "osascript -e \(Self.shellQuote(script))"
            guard let output = try? Self.runSync(command, cwd: workspace, timeout: 60) else {
                return .fail("osascript не выполнился.")
            }
            let (status, detail) = Self.splitExit(output)
            guard status == 0 else {
                return .fail("Письмо не отправлено (exit \(status)): "
                    + String(detail.prefix(600)) + "\nНужен грант Automation для Mail "
                    + "(x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Automation).")
            }
            return .ok("Письмо отправлено через Mail: \(recipients.count) адресат(ов).")

        case "airdrop":
            let paths = Self.stringList(args["paths"]).map(resolve)
            guard !paths.isEmpty else { return .fail("paths обязателен: файлы для AirDrop.") }
            guard paths.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                return .fail("Часть файлов не найдена.")
            }
            guard ShareControl.airDrop(paths) else {
                return .fail("Сервис AirDrop недоступен.")
            }
            return .ok("Панель AirDrop открыта для \(paths.count) файл(ов). "
                + "Получателя выбирает человек; «отправлено» не подтверждаю.")

        default:
            return .fail("action: compose | send | airdrop | services")
        }
    }
}
