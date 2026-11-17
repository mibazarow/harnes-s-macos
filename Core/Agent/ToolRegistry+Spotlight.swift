import Foundation

/// R25.5: search the whole machine, not just the workspace.
///
/// `fs_glob` and `fs_grep` are sandboxed to the workspace by design, so "where did that
/// PDF go" was answered by a shell `mdfind`. `NSMetadataQuery` is the same index without
/// the shell: one request, structured attributes, and the Spotlight index already knows
/// about every mounted volume the system has indexed.
enum SpotlightSearch {
    struct Item {
        let path: String
        let size: Int64?
        let modified: Date?
        let kind: String?
    }

    /// NSMetadataQuery needs a run loop and delivers results by notification, so it runs
    /// on its own thread and hands the answer back through a continuation. The timeout
    /// is real: a query scoped to `/` on a cold index can otherwise gather forever.
    static func search(
        text: String,
        scope: String,
        limit: Int,
        timeout: TimeInterval = 15
    ) async -> (items: [Item], timedOut: Bool) {
        await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            let thread = Thread {
                let query = NSMetadataQuery()
                query.predicate = NSPredicate(
                    format: "kMDItemFSName LIKE %@ OR kMDItemDisplayName LIKE %@",
                    "*\(text)*", "*\(text)*"
                )
                query.searchScopes = scopes(for: scope)
                query.sortDescriptors = [
                    NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)
                ]
                query.notificationBatchingInterval = 0.2

                let collector = Collector(query: query, limit: limit, once: once)
                NotificationCenter.default.addObserver(
                    collector,
                    selector: #selector(Collector.finished(_:)),
                    name: .NSMetadataQueryDidFinishGathering,
                    object: query
                )
                query.start()
                // A run loop is what makes the notification arrive at all.
                CFRunLoopRunInMode(.defaultMode, timeout, false)
                query.stop()
                once.resume(items: collector.items, timedOut: true)
                CFRunLoopStop(CFRunLoopGetCurrent())
            }
            thread.name = "harness.spotlight"
            thread.stackSize = 1 << 21
            thread.start()
        }
    }

    static func scopes(for scope: String) -> [Any] {
        switch scope.lowercased() {
        case "computer", "all": return [NSMetadataQueryLocalComputerScope]
        case "home", "": return [NSMetadataQueryUserHomeScope]
        case "network": return [NSMetadataQueryNetworkScope]
        default:
            // An explicit path keeps the query cheap when the user knows the volume.
            return [scope.hasPrefix("/") ? scope : NSMetadataQueryUserHomeScope]
        }
    }

    /// Spotlight can be switched off system-wide (`mdutil -s /` → "Indexing and
    /// searching disabled"). The query then returns zero results in milliseconds, and
    /// "nothing found" reads as "the file does not exist" — the most expensive kind of
    /// wrong answer, because it sends the caller looking for another explanation.
    static func indexingDisabled(volume: String = "/") -> Bool {
        guard let output = try? ToolRegistry.runSync(
            "export LC_ALL=C; mdutil -s \(ToolRegistry.shellQuote(volume))",
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 5
        ) else { return false }
        return ToolRegistry.splitExit(output).body.lowercased().contains("disabled")
    }

    /// Fallback when Spotlight is off: walk the scope by name with a depth cap and a
    /// hard time limit. Slower than an index and shallower than a full walk, but it
    /// answers "where is that file" instead of "the answer cannot be known".
    static func findByName(_ text: String, scope: String, limit: Int) -> [Item] {
        let root = scope.hasPrefix("/") ? scope : NSHomeDirectory()
        // Skip Library: it holds millions of cache files and never answers this question.
        let command = "export LC_ALL=C; find \(ToolRegistry.shellQuote(root)) -maxdepth 8 "
            + "-iname \(ToolRegistry.shellQuote("*\(text)*")) "
            + "-not -path '*/Library/*' -not -path '*/.git/*' 2>/dev/null | head -\(limit)"
        guard let output = try? ToolRegistry.runSync(
            command,
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 20
        ) else { return [] }
        return ToolRegistry.splitExit(output).body
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }
            .map { path in
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                return Item(
                    path: path,
                    size: (attributes?[.size] as? NSNumber)?.int64Value,
                    modified: attributes?[.modificationDate] as? Date,
                    kind: nil
                )
            }
    }

    static func line(for item: Item) -> String {
        var parts = [item.path]
        if let size = item.size {
            parts.append(String(format: "%@", ByteCountFormatter.string(
                fromByteCount: size, countStyle: .file
            )))
        }
        if let modified = item.modified {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            parts.append(formatter.string(from: modified))
        }
        if let kind = item.kind { parts.append(kind) }
        return parts.joined(separator: " · ")
    }

    /// Resumes the continuation exactly once: the notification and the timeout race,
    /// and a double resume traps.
    final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private let continuation: CheckedContinuation<(items: [Item], timedOut: Bool), Never>

        init(_ continuation: CheckedContinuation<(items: [Item], timedOut: Bool), Never>) {
            self.continuation = continuation
        }

        func resume(items: [Item], timedOut: Bool) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            continuation.resume(returning: (items, timedOut))
        }
    }

    final class Collector: NSObject {
        private let query: NSMetadataQuery
        private let limit: Int
        private let once: ResumeOnce
        private(set) var items: [Item] = []

        init(query: NSMetadataQuery, limit: Int, once: ResumeOnce) {
            self.query = query
            self.limit = limit
            self.once = once
        }

        @objc func finished(_ notification: Notification) {
            query.disableUpdates()
            let count = min(query.resultCount, limit)
            for index in 0..<count {
                guard let result = query.result(at: index) as? NSMetadataItem else { continue }
                let path = result.value(forAttribute: NSMetadataItemPathKey) as? String ?? "?"
                let size = (result.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?
                    .int64Value
                let modified = result.value(forAttribute: NSMetadataItemFSContentChangeDateKey)
                    as? Date
                let kind = result.value(forAttribute: NSMetadataItemContentTypeKey) as? String
                items.append(Item(path: path, size: size, modified: modified, kind: kind))
            }
            once.resume(items: items, timedOut: false)
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
    }
}

extension ToolRegistry {
    func spotlightTool(_ args: [String: Any]) async -> ToolResult {
        guard let text = args["query"] as? String ?? args["text"] as? String,
              !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .fail("query обязателен: подстрока имени файла")
        }
        let limit = min(max(Self.int(args, "limit") ?? 20, 1), 100)
        let scope = args["scope"] as? String ?? "home"
        let result = await SpotlightSearch.search(text: text, scope: scope, limit: limit)

        if result.items.isEmpty, SpotlightSearch.indexingDisabled() {
            let fallback = SpotlightSearch.findByName(text, scope: scope, limit: limit)
            guard !fallback.isEmpty else {
                return .fail("Индекс Spotlight отключён (mdutil -s / → disabled), и поиск по "
                    + "файловой системе не нашёл «\(text)» в пределах 8 уровней от \(scope). "
                    + "Включить индекс: sudo mdutil -i on /.")
            }
            let lines = fallback.map(SpotlightSearch.line(for:))
            return .ok("Индекс Spotlight отключён — искал по файловой системе, "
                + "\(lines.count) найдено:\n" + lines.joined(separator: "\n"))
        }
        guard !result.items.isEmpty else {
            return result.timedOut
                ? .fail("Spotlight не ответил за 15 с (индекс ещё строится?). Сузь scope до пути.")
                : .ok("Ничего не найдено по «\(text)» в \(scope).")
        }
        var lines = result.items.map(SpotlightSearch.line(for:))
        if result.timedOut {
            lines.append("(ответ неполный: запрос прерван по таймауту)")
        }
        return .ok("\(lines.count) найдено:\n" + lines.joined(separator: "\n"))
    }
}
