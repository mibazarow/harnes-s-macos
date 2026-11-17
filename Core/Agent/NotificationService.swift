import Foundation
import UserNotifications

/// R19.1: a notification is how the assistant says "готово" without the person watching
/// the chat. Authorization is requested once; a refusal is reported, never swallowed.
final class NotificationService: @unchecked Sendable {
    static let settingsPanel =
        "x-apple.systempreferences:com.apple.Notifications-Settings.extension"

    static func statusText(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional: return "authorized"
        case .denied: return "denied"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    /// `nil` on success, otherwise the reason the notification was not sent.
    func send(title: String, body: String) async -> String? {
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard status == .authorized || status == .provisional else {
            return "notifications: \(Self.statusText(status)). Выдай разрешение в "
                + "«Системные настройки → Уведомления → Harness» (\(Self.settingsPanel))."
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        do {
            try await center.add(request)
            return nil
        } catch {
            return "Уведомление не доставлено: \(error.localizedDescription)"
        }
    }
}
