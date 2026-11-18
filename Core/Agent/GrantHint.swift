import Foundation

/// R32.1: when a call fails on a missing grant, say which panel to open.
///
/// A refusal in the transcript used to be just text, and the person had to guess what
/// to click. The mapping here is deliberately narrow: only signatures that really mean
/// "TCC said no". A refusal that no setting can fix — SIP, `task_for_pid`, a locked
/// screen, a secure text field — gets no hint at all, because a hint there would be a
/// lie about what is possible.
enum GrantHint {
    struct Match: Equatable, Sendable {
        /// `GrantInventory` name, so the hint and `system permissions` agree.
        let grant: String
        let panel: String?
        let instruction: String
    }

    /// Signatures that mean "not granted", per grant. Matched case-insensitively.
    static let signatures: [(grant: String, needles: [String])] = [
        ("screen_recording", [
            "screen recording", "screenrecording", "cgpreflightscreencaptureaccess",
            "screencapture", "scstream", "scshareablecontent", "чёрный кадр", "черный кадр"
        ]),
        ("accessibility", [
            "axIsProcessTrusted".lowercased(), "kaxerrorapidisabled", "-25211",
            "accessibility", "axuielement", "not trusted", "не выдано разрешение на управление"
        ]),
        ("calendars", [
            "ekerror", "calendar access", "eventkit", "not authorized for calendars",
            "нет доступа к календар"
        ]),
        ("reminders", ["reminder access", "not authorized for reminders"]),
        ("contacts", ["cncontactstore", "contacts access", "not authorized for contacts"]),
        ("automation", [
            "erraeeventnotpermitted", "-1743", "not authorized to send apple events",
            "apple events"
        ]),
        ("location", ["kclerrordenied", "location services", "ssid"])
    ]

    /// Refusals no setting can grant. Checked first, so "operation not permitted" on a
    /// system path never turns into an Accessibility hint.
    static let ungrantable: [String] = [
        "task_for_pid", "tcc.db", "system integrity protection", "sip is enabled",
        "axsecuretextfield", "screen is locked", "filevault", "secure input",
        "/var/db/tcc", "operation not permitted on /system"
    ]

    static func panelTitle(osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) -> String {
        // macOS 13 renamed the pane; anything this app runs on is past that, but the
        // check stays explicit so an old machine gets the old name.
        osVersion.majorVersion >= 13 ? "Конфиденциальность и безопасность" : "Защита и безопасность"
    }

    static func match(
        output: String,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> Match? {
        let lower = output.lowercased()
        guard !ungrantable.contains(where: { lower.contains($0) }) else { return nil }
        guard let hit = signatures.first(where: { entry in
            entry.needles.contains { lower.contains($0) }
        }) else { return nil }
        return Match(
            grant: hit.grant,
            panel: TCCPanels.url(for: hit.grant),
            instruction: instruction(for: hit.grant, osVersion: osVersion)
        )
    }

    static func instruction(
        for grant: String,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        let panel = panelTitle(osVersion: osVersion)
        let title = grant.replacingOccurrences(of: "_", with: " ")
        return "Открой Системные настройки → \(panel) → \(title) и включи HARNES-S. "
            + "Разрешение выдаёт человек: приложение может открыть панель, но не отметить галочку."
    }

    /// One line appended to a failed tool result, or nil when there is nothing honest
    /// to add.
    static func line(
        for output: String,
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String? {
        guard let match = match(output: output, osVersion: osVersion) else { return nil }
        var line = "Похоже на отказ в гранте «\(match.grant)». \(match.instruction)"
        if let panel = match.panel {
            line += "\nПанель: \(panel)"
        }
        return line
    }
}
