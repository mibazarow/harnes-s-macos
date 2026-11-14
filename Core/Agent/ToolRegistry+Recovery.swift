import Foundation

extension ToolRegistry {
// MARK: - Reversible deletion
    func trashPaths(_ args: [String: Any]) async throws -> ToolResult {
        guard let fileSafety else { return .fail("Корзина недоступна") }
        guard let raw = args["paths"] as? [String], !raw.isEmpty else {
            return .fail("paths обязателен")
        }

        var moved: [String] = []
        for path in raw {
            let url = resolve(path)
            guard url.path != workspace.path else {
                return .fail("Нельзя удалить саму рабочую папку.")
            }
            if let refusal = writeGuard(url) { return refusal }
            do {
                let entry = try await fileSafety.trash(url)
                await ledger.forget(url)
                moved.append("#\(entry.id) \(entry.originalPath)")
            } catch {
                return .fail("\(path): \(error.localizedDescription)")
            }
        }
        return .ok("В корзину:\n" + moved.joined(separator: "\n"))
    }

    func undoList() async throws -> ToolResult {
        guard let fileSafety else { return .fail("Корзина недоступна") }
        let entries = try await fileSafety.listTrash()
        guard !entries.isEmpty else { return .ok("Корзина пуста.") }
        return .ok(entries.map { "#\($0.id) \($0.originalPath) — \($0.createdAt)" }.joined(separator: "\n"))
    }

    func restoreTrashed(_ args: [String: Any]) async throws -> ToolResult {
        guard let fileSafety else { return .fail("Корзина недоступна") }
        guard let id = Self.int(args, "id").map(Int64.init) else {
            return .fail("Нужен id")
        }
        let path = try await fileSafety.restore(id)
        await ledger.forget(resolve(path))
        return .ok("Восстановлено: \(path)")
    }

    func fileVersions(_ args: [String: Any]) async throws -> ToolResult {
        guard let fileSafety else { return .fail("Версии недоступны") }
        guard let path = args["path"] as? String else { return .fail("path обязателен") }
        let versions = try await fileSafety.versions(for: resolve(path).path)
        guard !versions.isEmpty else { return .ok("Версий нет.") }
        return .ok(versions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))
    }

    func restoreVersion(_ args: [String: Any]) async throws -> ToolResult {
        guard let fileSafety else { return .fail("Версии недоступны") }
        guard let path = args["path"] as? String, let version = args["version"] as? String else {
            return .fail("Нужны path и version")
        }
        let target = resolve(path)
        try await fileSafety.restoreVersion(version, to: target.path)
        await ledger.forget(target)
        return .ok("Восстановлено из версии: \(display(target))")
    }
}

extension ToolRegistry {
// MARK: - App logs

    /// Reads the app's own logs without shelling out to `bash`.
    ///
    /// Self-diagnosis used `bash tail/grep` on `~/HARNES_S_DATA/logs`, which is a
    /// policy bypass for a read that the app should simply allow.
    func appLogs(_ args: [String: Any]) async throws -> ToolResult {
        let directory = AppPaths.logsDirectory
        var names: [String]
        if let name = args["name"] as? String, !name.isEmpty {
            names = [name]
        } else {
            names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
                .filter { $0.hasSuffix(".log") }
                .sorted() ?? []
        }
        guard !names.isEmpty else { return .ok("Логов нет.") }

        let limit = max(1, min(Self.int(args, "limit") ?? 200, 2_000))
        let level = (args["level"] as? String)?.lowercased()
        let since = (args["since"] as? String).flatMap(Self.parseSince)

        var out: [String] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            // Read the tail first: logs are append-only, and the last lines are what a
            // diagnosis needs.
            let window = try FileLines.read(url, offset: -(limit * 4), limit: limit * 4)
            for line in window.lines {
                let text = line.text
                if let level, !text.lowercased().contains(level) { continue }
                if let since, Self.timestamp(of: text) < since { continue }
                out.append("\(name):\(line.number): \(text)")
            }
        }
        guard !out.isEmpty else { return .ok("По фильтру ничего не найдено.") }
        return .ok(out.suffix(limit).joined(separator: "\n"))
    }

    /// `since` accepts ISO8601 or a short relative span: `15m`, `2h`, `1d`.
    static func parseSince(_ text: String) -> Date? {
        if let date = parseISO8601(text) { return date }
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard let unit = value.last, let amount = Double(value.dropLast()) else { return nil }
        let seconds: Double
        switch unit {
        case "s": seconds = amount
        case "m": seconds = amount * 60
        case "h": seconds = amount * 3_600
        case "d": seconds = amount * 86_400
        default: return nil
        }
        return Date().addingTimeInterval(-seconds)
    }

    private static func timestamp(of line: String) -> Date {
        let prefix = String(line.prefix(25))
        return parseISO8601(prefix) ?? .distantPast
    }
}
