import Foundation

extension ToolRegistry {
    /// R20.2: one `git` tool with an action instead of a dozen names. Destructive forms
    /// (`--force`, `reset --hard`, `clean -fdx`) are refused outright.
    func gitTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "status"
        let cwd = resolve(args["cwd"] as? String ?? ".")
        guard FileManager.default.fileExists(atPath: cwd.appendingPathComponent(".git").path) else {
            return .fail("Не git-репозиторий: \(display(cwd))")
        }

        switch action {
        case "status":
            return await gitJSON(cwd)
        case "fetch":
            return await gitRun("fetch --all --prune", cwd)
        case "pull":
            return await gitRun("pull --ff-only", cwd)
        case "push":
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("push требует confirm: true — это внешнее действие. "
                    + "Принудительный push недоступен вовсе.")
            }
            return await gitRun("push", cwd)
        case "branch":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return await gitRun("branch --all --verbose", cwd)
            }
            if let from = args["from"] as? String, !from.isEmpty {
                return await gitRun("branch \(Self.shellQuote(name)) \(Self.shellQuote(from))", cwd)
            }
            return await gitRun("branch \(Self.shellQuote(name))", cwd)
        case "switch", "checkout":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return .fail("name обязателен")
            }
            return await gitRun("switch \(Self.shellQuote(name))", cwd)
        case "merge":
            guard let name = args["name"] as? String, !name.isEmpty else {
                return .fail("name обязателен")
            }
            return await gitRun("merge --no-edit \(Self.shellQuote(name))", cwd)
        case "show":
            return await gitRun("show --stat " + Self.shellQuote(args["ref"] as? String ?? "HEAD"), cwd)
        case "blame":
            guard let path = args["path"] as? String else { return .fail("path обязателен") }
            return await gitRun("blame -- " + Self.shellQuote(path), cwd)
        case "conflicts":
            return await conflicts(cwd)
        default:
            return .fail("action: status | fetch | pull | push | branch | switch | merge | show | blame | conflicts")
        }
    }

    private func gitRun(_ command: String, _ cwd: URL) async -> ToolResult {
        do {
            let output = try Self.runSync("git \(command)", cwd: cwd, timeout: 120)
            let (status, body) = Self.splitExit(output)
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return status == 0
                ? .ok(text.isEmpty ? "(без вывода)" : text)
                : .fail("git \(command): exit \(status)\n" + String(text.prefix(2_000)))
        } catch {
            return .fail(error.localizedDescription)
        }
    }

    /// Structured status: branch, ahead/behind, staged, modified, untracked, conflicts.
    private func gitJSON(_ cwd: URL) async -> ToolResult {
        let raw = try? Self.runSync(
            "git status --porcelain=v2 --branch", cwd: cwd, timeout: 30
        )
        guard let raw else { return .fail("git status не выполнился") }
        let (status, body) = Self.splitExit(raw)
        guard status == 0 else { return .fail("git status: \(body.prefix(500))") }

        var branch = "", ahead = 0, behind = 0
        var staged: [String] = [], modified: [String] = [], untracked: [String] = []
        var conflicts: [String] = []
        for line in body.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.split(separator: " ")
                if parts.count == 4 {
                    ahead = Int(parts[2].dropFirst()) ?? 0
                    behind = Int(parts[3].dropFirst()) ?? 0
                }
            } else if line.hasPrefix("1 ") || line.hasPrefix("2 ") {
                let parts = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: true)
                let xy = parts.count > 1 ? String(parts[1]) : "??"
                let path = parts.last.map(String.init) ?? ""
                if xy.contains("U") || xy == "AA" || xy == "DD" { conflicts.append(path) }
                if xy.first != "." { staged.append(path) }
                if xy.count > 1, xy.last != "." { modified.append(path) }
            } else if line.hasPrefix("? ") {
                untracked.append(String(line.dropFirst(2)))
            } else if line.hasPrefix("u ") {
                conflicts.append(String(line.split(separator: " ").last ?? ""))
            }
        }
        var out = ["branch=\(branch.isEmpty ? "detached" : branch) ahead=\(ahead) behind=\(behind)"]
        for (label, list) in [("staged", staged), ("modified", modified),
                              ("untracked", untracked), ("conflicts", conflicts)] where !list.isEmpty {
            out.append("\(label): " + list.joined(separator: ", "))
        }
        return .ok(out.joined(separator: "\n"))
    }

    private func conflicts(_ cwd: URL) async -> ToolResult {
        guard let raw = try? Self.runSync(
            "git diff --name-only --diff-filter=U", cwd: cwd, timeout: 30
        ) else { return .fail("git diff не выполнился") }
        let (_, body) = Self.splitExit(raw)
        let files = body.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        return .ok(files.isEmpty ? "Конфликтов нет." : "Конфликты:\n" + files.joined(separator: "\n")
            + "\nРазреши файл и повтори git status; ours/theirs помечай вручную или через bash.")
    }
}
