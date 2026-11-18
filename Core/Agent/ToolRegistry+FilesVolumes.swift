import Foundation

extension ToolRegistry {
    /// R25.4: volumes, DMG images and ejection without a shell detour.
    func filesTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "volumes"
        switch action {
        case "volumes":
            let keys: [URLResourceKey] = [
                .volumeNameKey, .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey, .volumeIsRemovableKey
            ]
            let urls = FileManager.default.mountedVolumeURLs(
                includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
            ) ?? []
            return .ok(urls.compactMap { url -> String? in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                let total = Double(values.volumeTotalCapacity ?? 0) / 1_073_741_824
                let free = Double(values.volumeAvailableCapacityForImportantUsage ?? 0) / 1_073_741_824
                return "\(values.volumeName ?? url.lastPathComponent): "
                    + String(format: "%.1f/%.1f GB", free, total)
                    + (values.volumeIsRemovable == true ? " removable" : "") + " \(url.path)"
            }.joined(separator: "\n"))
        case "eject":
            guard let target = (args["path"] as? String) ?? (args["name"] as? String) else {
                return .fail("path или name обязателен")
            }
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("eject требует confirm: true: это отключает том.")
            }
            return await runVolumeCommand("diskutil eject \(Self.shellQuote(target))")
        case "dmg_mount":
            guard let path = args["path"] as? String else { return .fail("path обязателен") }
            let url = resolve(path)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return .fail("Образ не найден: \(display(url))")
            }
            return await runVolumeCommand(
                "hdiutil attach -nobrowse -readonly \(Self.shellQuote(url.path))"
            )
        case "dmg_unmount":
            guard let path = args["path"] as? String else { return .fail("path обязателен") }
            return await runVolumeCommand("hdiutil detach \(Self.shellQuote(path))")
        default:
            return .fail("action: volumes | eject | dmg_mount | dmg_unmount")
        }
    }

    private func runVolumeCommand(_ command: String) async -> ToolResult {
        do {
            let output = try Self.runSync(command, cwd: workspace, timeout: 60)
            let (status, body) = Self.splitExit(output)
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return status == 0 ? .ok(text.isEmpty ? "(готово)" : text)
                : .fail("exit \(status): " + String(text.prefix(1_000)))
        } catch {
            return .fail(error.localizedDescription)
        }
    }
}
