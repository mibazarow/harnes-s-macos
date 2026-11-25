import Foundation

/// R18.8: a UI action must never grant itself the permissions it is bounded by.
/// Clicks in System Settings are refused without an explicit `confirm`.
final class SystemUIGuardInterceptor: ToolInterceptor, @unchecked Sendable {
    let name = "system_ui_guard"

    func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> GuardVerdict {
        guard call.name == "ui" else { return .pass }
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String else { return .pass }
        let confirmed = object["confirm"] as? Bool ?? false

        if action == "menu_click", !confirmed,
           let titles = object["path_titles"] as? [String] {
            let dangerous = ["erase", "format", "reset", "remove", "delete",
                             "стереть", "удалить", "сбросить", "отключить sip"]
            if let hit = titles.first(where: { title in
                dangerous.contains { title.lowercased().contains($0) }
            }) {
                return .deny(
                    reason: "опасный пункт меню «\(hit)» без подтверждения",
                    guidance: "Повтори с confirm: true, если это действительно нужно."
                )
            }
        }

        guard ["click", "set_value"].contains(action), !confirmed,
              let app = object["app"] as? String else { return .pass }
        let lowered = app.lowercased()
        let settings = lowered.contains("system settings") || lowered.contains("системные настройки")
        guard settings else { return .pass }
        return .deny(
            reason: "нажатие в Системных настройках без подтверждения",
            guidance: "Гранты TCC выдаёт человек. Если действие действительно нужно, "
                + "повтори вызов с confirm: true."
        )
    }
}
