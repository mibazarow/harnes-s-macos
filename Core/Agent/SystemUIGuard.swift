import Foundation

/// R18.8: a UI action must never grant itself the permissions it is bounded by.
/// Clicks in System Settings are refused without an explicit `confirm`.
final class SystemUIGuardInterceptor: ToolInterceptor, @unchecked Sendable {
    let name = "system_ui_guard"

    func beforeCall(_ call: ToolCall, context: ToolCallContext) async throws -> ToolVerdict {
        guard call.name == "ui", call.arguments.contains("\"confirm\"") == false else { return .allow }
        guard let data = call.arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let action = object["action"] as? String, ["click", "set_value"].contains(action),
              let app = object["app"] as? String else { return .allow }

        let lowered = app.lowercased()
        let settings = lowered.contains("system settings") || lowered.contains("системные настройки")
        guard settings else { return .allow }
        return .deny(
            reason: "нажатие в Системных настройках без подтверждения",
            guidance: "Гранты TCC выдаёт человек. Если действие действительно нужно, "
                + "повтори вызов с confirm: true."
        )
    }
}
