import AppKit
import ApplicationServices
import Carbon
import Contacts
import CoreBluetooth
import CoreLocation
import EventKit
import Foundation

/// R25.11: the answer to "а почему не работает" — every grant this app can check, in one
/// place, with the panel path for each denied one. TCC is never written here: the person
/// ticks the box, the app only reports and opens the panel.
enum GrantInventory {
    enum State: String, Sendable {
        case granted, denied, unknown, limited, writeOnly

        var isDenied: Bool { self == .denied }
    }

    struct Grant: Equatable, Sendable {
        let name: String
        let state: State
        let panel: String?
        let note: String?
    }

    static func all() -> [Grant] {
        [
            Grant(name: "accessibility",
                  state: AXIsProcessTrusted() ? .granted : .denied,
                  panel: TCCPanels.url(for: "accessibility"),
                  note: "клики, клавиши, AX-дерево"),
            Grant(name: "screen_recording",
                  state: CGPreflightScreenCaptureAccess() ? .granted : .denied,
                  panel: TCCPanels.url(for: "screen_recording"),
                  note: "screenshot, ocr, поток кадров"),
            Grant(name: "full_disk_access",
                  state: fullDiskAccess(),
                  panel: TCCPanels.url(for: "full_disk_access"),
                  note: "чтение чужих папок вне выбранного workspace"),
            Grant(name: "calendars",
                  state: eventKit(.event),
                  panel: TCCPanels.url(for: "calendars"),
                  note: "EventKit"),
            Grant(name: "reminders",
                  state: eventKit(.reminder),
                  panel: TCCPanels.url(for: "reminders"),
                  note: "EventKit"),
            Grant(name: "contacts",
                  state: contacts(),
                  panel: TCCPanels.url(for: "contacts"),
                  note: "CNContactStore"),
            Grant(name: "location",
                  state: location(),
                  panel: TCCPanels.url(for: "location"),
                  note: "нужен для SSID/BSSID Wi-Fi"),
            Grant(name: "bluetooth",
                  state: bluetooth(),
                  panel: TCCPanels.url(for: "bluetooth"),
                  note: "CoreBluetooth"),
            Grant(name: "automation_finder",
                  state: automation(bundleID: "com.apple.finder"),
                  panel: TCCPanels.url(for: "automation"),
                  note: "Apple Events; спрашивается для Finder, другие цели — свой диалог")
        ]
    }

    static func text(_ grants: [Grant] = all()) -> String {
        var lines = grants.map { grant -> String in
            var line = "\(grant.name)=\(grant.state.rawValue)"
            if let note = grant.note { line += " — \(note)" }
            return line
        }
        let denied = grants.filter { $0.state.isDenied }
        if denied.isEmpty {
            lines.append("Все проверяемые гранты на месте.")
        } else {
            lines.append("Отказано: " + denied.map(\.name).joined(separator: ", "))
            for grant in denied {
                if let panel = grant.panel {
                    lines.append("  \(grant.name): \(panel)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    /// FDA is not queryable; the probe is a protected directory that exists on every Mac.
    static func fullDiskAccess() -> State {
        let candidates = ["~/Library/Safari", "~/Library/Mail", "~/Library/Messages"]
        for candidate in candidates {
            let path = (candidate as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                _ = try FileManager.default.contentsOfDirectory(atPath: path)
                return .granted
            } catch {
                return .denied
            }
        }
        return .unknown
    }

    static func eventKit(_ entity: EKEntityType) -> State {
        switch EKEventStore.authorizationStatus(for: entity) {
        case .fullAccess: return .granted
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    static func contacts() -> State {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized: return .granted
        case .limited: return .limited
        case .denied: return .denied
        case .restricted: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    static func location() -> State {
        switch CLLocationManager().authorizationStatus {
        case .authorized, .authorizedAlways: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    static func bluetooth() -> State {
        switch CBCentralManager.authorization {
        case .allowedAlways: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    /// `askUserIfNeeded: false` on purpose: a status read must not pop a dialog.
    static func automation(bundleID: String) -> State {
        var address = AEAddressDesc()
        let data = Data(bundleID.utf8)
        let created = data.withUnsafeBytes { buffer in
            AECreateDesc(DescType(typeApplicationBundleID), buffer.baseAddress,
                         data.count, &address)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&address) }
        let status = AEDeterminePermissionToAutomateTarget(
            &address, typeWildCard, typeWildCard, false
        )
        switch status {
        case noErr: return .granted
        case OSStatus(-1743): return .denied      // errAEEventNotPermitted
        case OSStatus(-1744): return .unknown     // would require user consent
        default: return .unknown
        }
    }
}

/// R25.11: panel URLs. Opening is not granting — that stays with the person (R18.0).
enum TCCPanels {
    static let services: [String: String] = [
        "accessibility": "Privacy_Accessibility",
        "screen_recording": "Privacy_ScreenCapture",
        "full_disk_access": "Privacy_AllFiles",
        "calendars": "Privacy_Calendars",
        "reminders": "Privacy_Reminders",
        "contacts": "Privacy_Contacts",
        "location": "Privacy_LocationServices",
        "automation": "Privacy_Automation",
        "bluetooth": "Privacy_Bluetooth",
        "microphone": "Privacy_Microphone",
        "camera": "Privacy_Camera"
    ]

    static func url(for service: String) -> String? {
        guard let name = services[service.lowercased()] else { return nil }
        return "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(name)"
    }

    static func open(_ service: String) -> Bool {
        guard let raw = url(for: service), let url = URL(string: raw) else { return false }
        return NSWorkspace.shared.open(url)
    }
}
