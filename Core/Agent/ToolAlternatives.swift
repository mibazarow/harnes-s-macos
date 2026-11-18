import Foundation

/// Curated "what else to try" for a tool that just failed.
///
/// A failed call returns an error and nothing else, so the model either repeats the same
/// call or gives up. A short list of different tools that reach the same goal is the
/// cheapest way out. The list is deliberately conservative:
///
/// - unknown tools get nothing, not a generic stub;
/// - irreversible actions are never suggested as an alternative, even when they would
///   work: a failed read may point at `bash`, a failed delete may not point at another
///   delete;
/// - `bash` counts as irreversible only when its own command is destructive, because
///   the same tool is also the safe fallback for `process` and `read`.
enum ToolAlternatives {
    static let maxSuggestions = 3
    static let maxItemChars = 80
    static let maxLineChars = 400
    static let prefix = "Попробуй также: "

    /// Safe neighbours, most useful first. Order matters: the first three survive.
    private static let registry: [String: [String]] = [
        "fs_read": ["read_many", "fs_grep", "bash"],
        "read_many": ["fs_read", "fs_grep"],
        "fs_list": ["fs_tree", "fs_glob"],
        "fs_glob": ["fs_grep", "fs_list"],
        "fs_grep": ["search_code", "bash"],
        "fs_tree": ["fs_list", "fs_glob"],
        "search_code": ["fs_grep", "fs_glob"],
        "webfetch": ["browser", "websearch"],
        "websearch": ["webfetch", "browser"],
        "browser": ["webfetch", "websearch"],
        "process": ["bash", "watch"],
        "watch": ["process", "bash"],
        "bash": ["fs_grep", "fs_read"],
        "doc_read": ["fs_read", "image_read"],
        "doc_write": ["fs_write", "apply_patch"],
        "image_read": ["ocr", "screenshot"],
        "ocr": ["image_read", "screenshot"],
        "screenshot": ["observe", "image_read"],
        "observe": ["screenshot", "ui"],
        "ui": ["screenshot", "mouse"],
        "mouse": ["ui", "keyboard"],
        "keyboard": ["ui", "bash"],
        "clipboard": ["bash", "fs_read"],
        "apply_patch": ["edit_file", "fs_write"],
        "edit_file": ["apply_patch", "fs_read"],
        "fs_write": ["edit_file", "apply_patch"],
        "fs_copy": ["bash", "fs_list"],
        "fs_move": ["bash", "fs_list"],
        "fs_mkdir": ["bash", "fs_list"],
        "files": ["fs_list", "spotlight"],
        "spotlight": ["fs_glob", "files"],
        "network": ["bash", "browser"],
        "power": ["bash", "settings"],
        "display": ["settings", "system"],
        "apps": ["windows", "bash"],
        "app_quit": ["apps", "bash"],
        "windows": ["apps", "ui"],
        "system": ["permissions", "activity"],
        "activity": ["app_logs", "system"],
        "app_logs": ["activity", "system"],
        "settings": ["system", "permissions"],
        "permissions": ["system", "settings"],
        "shortcut": ["app_script", "bash"],
        "app_script": ["shortcut", "bash"],
        "launchd": ["process", "bash"],
        "calendar": ["shortcut", "bash"],
        "contacts": ["shortcut", "memory_search"],
        "share": ["bash", "files"],
        "notify": ["bash", "app_script"],
        "git": ["git_status", "bash"],
        "git_status": ["git_diff", "git_log"],
        "git_diff": ["git_status", "git_log"],
        "git_log": ["git_status", "git_diff"],
        "git_commit": ["git_status", "git_diff"],
        "git_stash": ["git_status", "bash"],
        "index_workspace": ["search_code", "project_overview"],
        "project_overview": ["fs_list", "index_workspace"],
        "memory_search": ["memory_list", "fs_grep"],
        "memory_list": ["memory_search"],
        "memory_add": ["memory_search"],
        "secret_search": ["secret_get", "memory_search"],
        "secret_get": ["secret_search"],
        "skill_list": ["skill_read", "skill_learn"],
        "skill_read": ["skill_list", "skill_learn"],
        "skill_learn": ["skill_list", "skill_read"],
        "skill_install": ["skill_list"],
        "mcp_list": ["mcp_tools"],
        "mcp_tools": ["mcp_list"],
        "tool_load": ["mcp_tools"],
        "restore_trashed": ["undo_list", "file_versions"],
        "restore_version": ["file_versions", "undo_list"],
        "undo_list": ["restore_version", "file_versions"],
        "file_versions": ["undo_list", "fs_read"]
    ]

    /// Actions that cannot be undone by the app, or that leave the machine. They may be
    /// the source of a suggestion, never its target.
    private static let irreversible: Set<String> = [
        "trash_paths", "app_quit", "windows", "secret_save", "memory_forget", "skill_remove"
    ]

    private static let destructiveBash: [String] = [
        "rm -rf", "rm -fr", "rm -r", "diskutil erase", "mkfs", "dd if=",
        "shutdown", "reboot", "killall", "pkill -9"
    ]

    static func suggestions(for tool: String, arguments: String? = nil) -> [String] {
        guard let candidates = registry[tool] else { return [] }
        var result: [String] = []
        for candidate in candidates {
            guard candidate != tool,
                  !result.contains(candidate),
                  !isIrreversible(candidate) else { continue }
            result.append(String(candidate.prefix(maxItemChars)))
            if result.count == maxSuggestions { break }
        }
        return result
    }

    /// One line for the tool result, or nil when there is nothing honest to add.
    static func format(tool: String, arguments: String? = nil) -> String? {
        let items = suggestions(for: tool, arguments: arguments)
        guard !items.isEmpty else { return nil }
        var line = prefix + items.joined(separator: ", ")
        if line.count > maxLineChars {
            line = String(line.prefix(maxLineChars - 1)) + "…"
        }
        return line
    }

    static func isIrreversible(_ tool: String, arguments: String? = nil) -> Bool {
        if irreversible.contains(tool) { return true }
        guard tool == "bash", let arguments else { return false }
        let command = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)))
            .flatMap { ($0 as? [String: Any])?["command"] as? String }?
            .lowercased() ?? arguments.lowercased()
        return destructiveBash.contains { command.contains($0) }
    }
}
