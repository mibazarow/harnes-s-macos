import AppKit
import Foundation

/// R26.3: mail, AirDrop and the list of sharing services. Compose is the default: the
/// person checks and presses Send. A real send needs `confirm` and is done through Mail
/// with Apple Events, whose refusal is reported as-is.
enum ShareControl {
    static func services() -> [String] {
        let items: [Any] = [NSURL(fileURLWithPath: NSTemporaryDirectory())]
        return NSSharingService.sharingServices(forItems: items)
            .map { "\($0.title)" }
            .sorted()
    }

    static func composeEmail(
        to recipients: [String], subject: String, body: String, attachments: [URL]
    ) -> Bool {
        guard let service = NSSharingService(named: .composeEmail) else { return false }
        if !recipients.isEmpty { service.recipients = recipients }
        service.subject = subject
        var items: [Any] = [body]
        items += attachments
        service.perform(withItems: items)
        return true
    }

    static func airDrop(_ items: [URL]) -> Bool {
        guard let service = NSSharingService(named: .sendViaAirDrop) else { return false }
        service.perform(withItems: items)
        return true
    }

    /// AppleScript for Mail. Pure so the escaping is testable: a subject with a quote
    /// must not end the string literal and turn the rest into code.
    static func emailScript(to recipients: [String], subject: String, body: String) -> String {
        let recipientLines = recipients.map {
            "make new to recipient at end of to recipients with properties {address:\"\(escape($0))\"}"
        }.joined(separator: "\n")
        return """
        tell application "Mail"
            set theMessage to make new outgoing message with properties {subject:"\(escape(subject))", content:"\(escape(body))", visible:false}
            tell theMessage
                \(recipientLines)
            end tell
            send theMessage
        end tell
        """
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }
}
