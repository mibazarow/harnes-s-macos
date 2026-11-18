import AppKit
import Darwin
import Foundation
import IOKit.ps

/// One-call machine state for R19.2: volumes, memory, power, thermal, load, uptime and
/// the top processes. Read-only. Replaces a pile of `df`/`vm_stat`/`pmset` calls whose
/// output changes with locale.
enum SystemReport {
    static func text(sections: Set<String> = [], diskPath: URL? = nil) -> String {
        let all = sections.isEmpty
        var lines: [String] = []

        if all || sections.contains("info") {
            lines.append(info)
        }

        if all || sections.contains("cpu") {
            lines.append(cpuLine)
        }

        if all || sections.contains("disk") {
            lines.append(contentsOf: diskLines(path: diskPath))
        }

        if all || sections.contains("load") {
            var load = [Double](repeating: 0, count: 3)
            getloadavg(&load, 3)
            lines.append(String(
                format: "uptime=%.0f s load=%.2f %.2f %.2f",
                ProcessInfo.processInfo.systemUptime, load[0], load[1], load[2]
            ))
            lines.append("thermal=\(thermal)")
        }

        if all || sections.contains("memory") {
            lines.append(memoryLine)
        }

        if all || sections.contains("power") {
            lines.append(powerLine)
        }

        if all || sections.contains("volumes") {
            lines.append("Тома:")
            lines.append(contentsOf: volumeLines)
        }

        if all || sections.contains("processes") {
            lines.append("Топ по памяти:")
            lines.append(contentsOf: topProcessLines)
        }

        return lines.joined(separator: "\n")
    }

    static var info: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var lines = [
            "model=\(sysctl("hw.model") ?? "?")",
            "chip=\(sysctl("machdep.cpu.brand_string") ?? "?")",
            "cores=\(ProcessInfo.processInfo.processorCount) "
                + "active=\(ProcessInfo.processInfo.activeProcessorCount)",
            String(format: "ram=%.0f GB", Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824),
            "macos=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) "
                + "build=\(sysctl("kern.osversion") ?? "?")",
            String(format: "uptime=%.0f s", ProcessInfo.processInfo.systemUptime),
            "host=\(ProcessInfo.processInfo.hostName)",
            "user=\(NSUserName())"
        ]
        lines.append(contentsOf: sessionLines)
        return lines.joined(separator: "\n")
    }

    /// Console user, lock state and remote sessions. This is what has to be known before
    /// any action: a locked screen makes every click land nowhere.
    static var sessionLines: [String] {
        guard let raw = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return ["session=unknown"]
        }
        var lines: [String] = []
        let console = (raw["kCGSSessionOnConsoleKey"] as? Bool) ?? false
        let locked = (raw["CGSSessionScreenIsLocked"] as? Bool) ?? false
        let user = raw["kCGSSessionUserNameKey"] as? String ?? "?"
        lines.append("session_console=\(console) session_locked=\(locked) session_user=\(user)")
        let remote = raw["kCGSSessionLoginDoneKey"] as? Bool ?? false
        lines.append("session_login_done=\(remote)")
        return lines
    }

    static var cpuLine: String {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        let top = topByCPU.joined(separator: " | ")
        return String(format: "load=%.2f %.2f %.2f", load[0], load[1], load[2])
            + (top.isEmpty ? "" : "\ntop cpu: " + top)
    }

    static var topByCPU: [String] {
        guard let output = try? ToolRegistry.runSync(
            "export LC_ALL=C; ps -Ao pid=,pcpu=,comm= -r | head -6",
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()), timeout: 5
        ) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { return nil }
            return "pid=\(parts[0]) \(parts[1])% \(parts[2])"
        }
    }

    static func diskLines(path: URL? = nil) -> [String] {
        var lines = ["Тома:"] + volumeLines
        let targets = [
            ("logs", AppPaths.logsDirectory),
            ("trash", AppPaths.trashDirectory),
            ("versions", AppPaths.versionsDirectory)
        ]
        let sizes = targets.map { name, url -> String in
            "\(name)=\(folderSize(url))"
        }
        lines.append("HARNES_S_DATA: " + sizes.joined(separator: " "))
        if let path {
            let top = largestFolders(in: path)
            lines.append("Топ по размеру в \(path.path):")
            lines.append(contentsOf: top.isEmpty ? ["  (пусто)"] : top.map { "  \($0)" })
        }
        return lines
    }

    static func folderSize(_ url: URL) -> String {
        guard FileManager.default.fileExists(atPath: url.path) else { return "0" }
        guard let output = try? ToolRegistry.runSync(
            "du -sk \(ToolRegistry.shellQuote(url.path))", cwd: url.deletingLastPathComponent(),
            timeout: 20
        ) else { return "?" }
        let (status, body) = ToolRegistry.splitExit(output)
        guard status == 0, let kb = Int(body.split(separator: "\t").first ?? "") else { return "?" }
        return gb(Int64(kb) * 1024)
    }

    static func largestFolders(in url: URL, limit: Int = 5) -> [String] {
        guard let output = try? ToolRegistry.runSync(
            "export LC_ALL=C; du -sk \(ToolRegistry.shellQuote(url.path))/* 2>/dev/null "
                + "| sort -rn | head -\(limit)",
            cwd: url, timeout: 30
        ) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = Int64(parts[0]) else { return nil }
            return "\(gb(kb * 1024)) \(parts[1])"
        }
    }

    static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static var thermal: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static var memoryLine: String {
        let total = UInt64(ProcessInfo.processInfo.physicalMemory)
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        var usedPercent = 0.0
        if result == KERN_SUCCESS {
            let page = UInt64(sysconf(_SC_PAGESIZE))
            let usedPages = UInt64(stats.active_count) + UInt64(stats.wire_count)
                + UInt64(stats.compressor_page_count)
            usedPercent = total > 0 ? Double(usedPages * page) / Double(total) * 100 : 0
        }
        return String(format: "memory_used=%.0f%% swap=%@", usedPercent, swap)
    }

    static var swap: String {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return "?" }
        return String(
            format: "%.1f/%.1f MB",
            Double(usage.xsu_used) / 1_048_576, Double(usage.xsu_total) / 1_048_576
        )
    }

    static var powerLine: String {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue()
                as? [CFTypeRef] else {
            return "power=unknown"
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            let state = description[kIOPSPowerSourceStateKey] as? String ?? "?"
            let capacity = description[kIOPSCurrentCapacityKey] as? Int
            let charging = description[kIOPSIsChargingKey] as? Bool
            var line = "power=\(state)"
            if let capacity { line += " charge=\(capacity)%" }
            if let charging { line += " charging=\(charging)" }
            return line
        }
        return "power=unknown"
    }

    static var volumeLines: [String] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey, .volumeIsRemovableKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let name = values.volumeName ?? url.lastPathComponent
            let total = Int64(values.volumeTotalCapacity ?? 0)
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            let removable = values.volumeIsRemovable == true ? " removable" : ""
            return "\(name): \(gb(free)) свободно из \(gb(total))\(removable) (\(url.path))"
        }
    }

    static var topProcessLines: [String] {
        // `ps` with a fixed locale: one internal call is cheaper than ranking by rusage
        // and still returns text the model never sees raw.
        // `-m` sorts by resident memory; `-r` sorts by CPU. The trailing `=` in the field
        // list suppresses the header, so no line may be dropped.
        guard let output = try? ToolRegistry.runSync(
            "export LC_ALL=C; ps -Ao pid=,rss=,comm= -m | head -6",
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 5
        ) else { return [] }
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let rss = Int(parts[1]) else { return nil }
            return "pid=\(parts[0]) rss=\(rss / 1024)MB \(parts[2])"
        }
    }

    private static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
