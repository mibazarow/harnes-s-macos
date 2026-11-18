import CoreWLAN
import Foundation

/// R25.9: Wi-Fi state through CoreWLAN. Since macOS 14 `ssid()`/`bssid()` are only
/// returned with a Location grant, so an empty answer is reported as `needs_location`
/// instead of "Wi-Fi is off".
enum WiFiControl {
    static func interface() -> CWInterface? {
        CWWiFiClient.shared().interface()
    }

    struct Status: Equatable, Sendable {
        let power: Bool
        let ssid: String?
        let bssid: String?
        let rssi: Int?
        let channel: String?
        let transmitRate: Double?
        let needsLocation: Bool
    }

    static func status() -> Status? {
        guard let interface = interface() else { return nil }
        let ssid = interface.ssid()
        let bssid = interface.bssid()
        let channel = interface.wlanChannel().map { "\($0.channelNumber)/\($0.channelBand.rawValue)" }
        let needsLocation = interface.powerOn() && (ssid == nil || bssid == nil)
        return Status(
            power: interface.powerOn(),
            ssid: ssid,
            bssid: bssid,
            rssi: interface.powerOn() ? interface.rssiValue() : nil,
            channel: channel,
            transmitRate: interface.powerOn() ? interface.transmitRate() : nil,
            needsLocation: needsLocation
        )
    }

    /// `networksetup` fallback: the only place it is used is the SSID the API hides.
    static func fallbackSSID(service: String = "Wi-Fi") -> String? {
        guard let output = try? ToolRegistry.runSync(
            "networksetup -getairportnetwork \(ToolRegistry.shellQuote(service))",
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()), timeout: 10
        ) else { return nil }
        let (status, body) = ToolRegistry.splitExit(output)
        guard status == 0 else { return nil }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let range = text.range(of: ": ") else { return nil }
        let value = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    struct Visible: Equatable, Sendable {
        let ssid: String
        let rssi: Int
        let channel: String?
        let secured: Bool
    }

    static func scan() -> [Visible]? {
        guard let interface = interface() else { return nil }
        guard let networks = try? interface.scanForNetworks(withSSID: nil) else { return nil }
        return networks.compactMap { network -> Visible? in
            guard let ssid = network.ssid, !ssid.isEmpty else { return nil }
            return Visible(
                ssid: ssid,
                rssi: network.rssiValue,
                channel: network.wlanChannel.map { "\($0.channelNumber)" },
                secured: !(network.supportsSecurity(.none))
            )
        }.sorted { $0.rssi > $1.rssi }
    }

    static func setPower(_ on: Bool) -> Bool {
        guard let interface = interface() else { return false }
        do {
            try interface.setPower(on)
            return true
        } catch {
            return false
        }
    }

    /// The password is passed through and never logged or echoed back.
    static func join(ssid: String, password: String) -> Bool {
        guard let interface = interface(),
              let networks = try? interface.scanForNetworks(withSSID: nil),
              let network = networks.first(where: { $0.ssid == ssid }) else { return false }
        do {
            try interface.associate(to: network, password: password)
            return true
        } catch {
            return false
        }
    }
}

/// R25.9: `scutil --nc list` lines look like
///     * (Connected)      ABC123 "Home VPN" [PPP:L2TP]
enum VPNReport {
    struct Tunnel: Equatable, Sendable {
        let status: String
        let id: String
        let name: String
        let kind: String?
    }

    private static let linePattern = try! NSRegularExpression(
        pattern: #"^\*?\s*\(([^)]+)\)\s+(\S+)\s+\"([^\"]*)\"(?:\s+\[([^\]]*)\])?"#
    )

    static func parse(_ output: String) -> [Tunnel] {
        var tunnels: [Tunnel] = []
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = linePattern.firstMatch(in: line, range: range) else { continue }
            func group(_ index: Int) -> String? {
                guard let range = Range(match.range(at: index), in: line) else { return nil }
                return String(line[range])
            }
            guard let status = group(1), let id = group(2), let name = group(3) else { continue }
            tunnels.append(Tunnel(status: status, id: id, name: name, kind: group(4)))
        }
        return tunnels
    }
}

/// R25.9: `networksetup -getwebproxy <service>` output.
struct ProxySettings: Equatable, Sendable {
    let enabled: Bool
    let server: String?
    let port: Int?

    static func parse(_ output: String) -> ProxySettings? {
        var values: [String: String] = [:]
        for raw in output.split(separator: "\n") {
            guard let separator = raw.firstIndex(of: ":") else { continue }
            let key = raw[raw.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = raw[raw.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        guard let enabled = values["Enabled"] else { return nil }
        return ProxySettings(
            enabled: enabled.lowercased() == "yes",
            server: values["Server"].flatMap { $0.isEmpty ? nil : $0 },
            port: values["Port"].flatMap(Int.init)
        )
    }

    var summary: String {
        "enabled: \(enabled ? "yes" : "no")"
            + (server.map { " server=\($0)" } ?? "")
            + (port.map { " port=\($0)" } ?? "")
    }
}
