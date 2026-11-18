import Foundation
import ServiceManagement

/// One agent from `launchctl print gui/$UID`.
struct LaunchdAgent: Equatable, Sendable {
    let label: String
    let pid: Int?
    let state: String
}

/// R25.6: login item, agents and Time Machine. `launchctl` and `tmutil` are used for the
/// return code, not for localized text; the parsing that is left is pure and tested.
enum LaunchdParser {
    /// The services block looks like:
    ///     0      0  com.apple.Finder
    ///     1234   0  com.example.agent
    /// A leading `-` in the pid column means "not running".
    static func parseAgents(_ output: String) -> [LaunchdAgent] {
        var agents: [LaunchdAgent] = []
        var inServices = false
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("services = {") { inServices = true; continue }
            if inServices, line == "}" { break }
            guard inServices else { continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 3 else { continue }
            let pidText = String(parts[0])
            let state = String(parts[1])
            let label = String(parts[2])
            guard label.contains("."), !label.hasPrefix("0x") else { continue }
            let pid = Int(pidText)
            agents.append(LaunchdAgent(label: label, pid: pid, state: state))
        }
        return agents.sorted { $0.label < $1.label }
    }

    /// `SMAppService.Status` as words the model can act on.
    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requires_approval"
        case .notRegistered: return "not_registered"
        case .notFound: return "not_found"
        @unknown default: return "unknown"
        }
    }
}

/// `tmutil status` prints a plist-ish dictionary:
///     Running = 1;
///     BackupPhase = Copying;
///     Percent = 0.42;
struct TimeMachineStatus: Equatable, Sendable {
    let running: Bool
    let phase: String?
    let percent: Int?
    let destination: String?

    static func parse(_ output: String) -> TimeMachineStatus? {
        var values: [String: String] = [:]
        for raw in output.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: " ;\""))
            values[key] = value
        }
        guard let runningText = values["Running"] else { return nil }
        let percent = values["Percent"].flatMap(Double.init).map { Int(($0 * 100).rounded()) }
        return TimeMachineStatus(
            running: runningText == "1" || runningText.lowercased() == "true",
            phase: values["BackupPhase"],
            percent: percent,
            destination: values["DestinationMountPoint"]
        )
    }

    var summary: String {
        var line = "running: \(running ? "yes" : "no")"
        if let phase { line += " phase=\(phase)" }
        if let percent { line += " percent=\(percent)%" }
        if let destination { line += " destination=\(destination)" }
        return line
    }
}
