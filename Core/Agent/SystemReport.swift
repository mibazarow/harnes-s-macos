import Darwin
import Foundation
import IOKit.ps

/// One-call machine state for R19.2: volumes, memory, power, thermal, load, uptime and
/// the top processes. Read-only. Replaces a pile of `df`/`vm_stat`/`pmset` calls whose
/// output changes with locale.
enum SystemReport {
    static func text(sections: Set<String> = []) -> String {
        let all = sections.isEmpty
        var lines: [String] = []

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
        guard let output = try? ToolRegistry.runSync(
            "export LC_ALL=C; ps -Ao pid=,rss=,comm= -r | head -6",
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 5
        ) else { return [] }
        return output.split(separator: "\n").dropFirst().compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let rss = Int(parts[1]) else { return nil }
            return "pid=\(parts[0]) rss=\(rss / 1024)MB \(parts[2])"
        }
    }

    private static func gb(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
