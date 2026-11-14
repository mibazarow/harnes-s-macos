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
        return .ok("Восстановлено из версии: \(display(target))")
    }
}
