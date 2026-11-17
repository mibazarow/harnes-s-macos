import Foundation

extension ToolRegistry {
    /// R20.5: copy, move and mkdir without a shell. Overwrite is refused by default and
    /// a move that leaves the workspace needs an explicit `confirm`.
    func fileOperation(_ action: String, _ args: [String: Any]) throws -> ToolResult {
        switch action {
        case "copy", "move":
            return try transfer(action, args)
        case "mkdir":
            guard let path = args["path"] as? String else { return .fail("path обязателен") }
            let url = resolve(path)
            if let refusal = writeGuard(url) { return refusal }
            if FileManager.default.fileExists(atPath: url.path) {
                return .ok("Каталог уже существует: \(display(url))")
            }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return .ok("Создан каталог: \(display(url))")
        default:
            return .fail("action: copy | move | mkdir")
        }
    }

    private func transfer(_ action: String, _ args: [String: Any]) throws -> ToolResult {
        guard let from = args["from"] as? String, let to = args["to"] as? String else {
            return .fail("from и to обязательны")
        }
        let source = resolve(from)
        let destination = resolve(to)
        guard FileManager.default.fileExists(atPath: source.path) else {
            return .fail("Источник не найден: \(display(source))")
        }
        if let refusal = writeGuard(destination) { return refusal }

        if action == "move", !isInsideWorkspace(destination),
           !(Self.bool(args, "confirm") ?? false) {
            return .fail("Перенос за пределы рабочей папки требует confirm: true "
                + "(\(display(destination))).")
        }

        let overwrite = Self.bool(args, "overwrite") ?? false
        let exists = FileManager.default.fileExists(atPath: destination.path)
        if exists, !overwrite {
            return .fail("Назначение уже существует: \(display(destination)). "
                + "Передай overwrite: true, если его можно заменить.")
        }

        let dryRun = Self.bool(args, "dry_run") ?? false
        let files = countFiles(source)
        if dryRun {
            return .ok("План: \(action == "copy" ? "скопировать" : "перенести") "
                + "\(display(source)) → \(display(destination)), файлов: \(files)"
                + (exists ? " (перезапись)" : ""))
        }

        try AppPaths.ensureDirectory(destination.deletingLastPathComponent())
        if exists, overwrite {
            try? FileManager.default.removeItem(at: destination)
        }
        if action == "copy" {
            try FileManager.default.copyItem(at: source, to: destination)
        } else {
            try FileManager.default.moveItem(at: source, to: destination)
        }
        return .ok("\(action == "copy" ? "Скопировано" : "Перенесено"): "
            + "\(display(source)) → \(display(destination)), файлов: \(files)"
            + (exists ? " (перезаписано)" : ""))
    }

    private func isInsideWorkspace(_ url: URL) -> Bool {
        let root = workspace.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path == root || path.hasPrefix(root + "/")
    }

    private func countFiles(_ url: URL) -> Int {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }
        guard isDirectory.boolValue else { return 1 }
        let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.isRegularFileKey]
        )
        var count = 0
        while let item = enumerator?.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { count += 1 }
        }
        return count
    }
}
