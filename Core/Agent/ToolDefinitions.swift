import Foundation

/// Tool catalog: JSON schemas sent to the model. Kept separate from the
/// implementation so `ToolRegistry.swift` stays navigable.
extension ToolRegistry {
    static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "fs_list",
            description: "List files in a directory. Relative paths resolve against the workspace.",
            parameters: schema(["path": ["type": "string", "description": "Directory path, default '.'"]], required: [])
        ),
        ToolDefinition(
            name: "fs_read",
            description: "Read a UTF-8 text file with line numbers.",
            parameters: schema([
                "path": ["type": "string", "description": "File path"],
                "offset": ["type": "integer", "description": "First line, 1-based"],
                "limit": ["type": "integer", "description": "Max lines, default 400"]
            ], required: ["path"])
        ),
        ToolDefinition(
            name: "fs_write",
            description: "Create or overwrite a file with the given content.",
            parameters: schema([
                "path": ["type": "string"],
                "content": ["type": "string"]
            ], required: ["path", "content"])
        ),
        ToolDefinition(
            name: "edit_file",
            description: "Replace the first exact occurrence of old_text with new_text.",
            parameters: schema([
                "path": ["type": "string"],
                "old_text": ["type": "string"],
                "new_text": ["type": "string"]
            ], required: ["path", "old_text", "new_text"])
        ),
        ToolDefinition(
            name: "apply_patch",
            description: "Apply a unified diff to one or more files. Preferred over full rewrites for multi-line edits.",
            parameters: schema([
                "path": ["type": "string", "description": "File the patch applies to"],
                "patch": ["type": "string", "description": "Unified diff with @@ hunks"]
            ], required: ["path", "patch"])
        ),
        ToolDefinition(
            name: "read_many",
            description: "Read several files in one call. Returns each file with line numbers and a size cap.",
            parameters: schema([
                "paths": ["type": "array", "items": ["type": "string"]],
                "limit": ["type": "integer", "description": "Max lines per file, default 200"]
            ], required: ["paths"])
        ),
        ToolDefinition(
            name: "project_overview",
            description: "Detect the project stack (Bitrix, PHP, Swift, Node, Python), build, test and lint commands.",
            parameters: schema([:], required: [])
        ),
        ToolDefinition(
            name: "search_code",
            description: "Semantic + keyword search over indexed workspace code. Run index_workspace first.",
            parameters: schema([
                "query": ["type": "string"],
                "limit": ["type": "integer", "description": "Default 8"]
            ], required: ["query"])
        ),
        ToolDefinition(
            name: "git_commit",
            description: "Stage given paths (or all changes) and commit with a message.",
            parameters: schema([
                "message": ["type": "string"],
                "paths": ["type": "array", "items": ["type": "string"], "description": "Empty = all changes"]
            ], required: ["message"])
        ),
        ToolDefinition(
            name: "git_stash",
            description: "Stash or pop working tree changes.",
            parameters: schema(["action": ["type": "string", "enum": ["push", "pop", "list"]]], required: ["action"])
        ),
        ToolDefinition(
            name: "fs_tree",
            description: "Show a compact directory tree (depth-limited), skipping noise folders.",
            parameters: schema([
                "path": ["type": "string"],
                "depth": ["type": "integer", "description": "Default 4, max 8"]
            ], required: [])
        ),
        ToolDefinition(
            name: "trash_paths",
            description: "Move files or folders to the app trash (reversible). Use instead of rm.",
            parameters: schema(["paths": ["type": "array", "items": ["type": "string"]]], required: ["paths"])
        ),
        ToolDefinition(
            name: "undo_list",
            description: "List trashed items that can be restored.",
            parameters: schema([:], required: [])
        ),
        ToolDefinition(
            name: "restore_trashed",
            description: "Restore an item from the app trash by its id.",
            parameters: schema(["id": ["type": "integer"]], required: ["id"])
        ),
        ToolDefinition(
            name: "file_versions",
            description: "List saved versions of a file that were snapshotted before edits.",
            parameters: schema(["path": ["type": "string"]], required: ["path"])
        ),
        ToolDefinition(
            name: "restore_version",
            description: "Restore a file to a previously snapshotted version.",
            parameters: schema([
                "path": ["type": "string"],
                "version": ["type": "string", "description": "stored_at from file_versions"]
            ], required: ["path", "version"])
        ),
        ToolDefinition(
            name: "task",
            description: "Delegate a self-contained job to a fresh subagent with its own context. Returns only its final answer. Use for long searches or parallel investigation.",
            parameters: schema([
                "prompt": ["type": "string", "description": "Full self-contained instruction"],
                "read_only": ["type": "boolean", "description": "true = investigation only, no edits"]
            ], required: ["prompt"])
        ),
        ToolDefinition(
            name: "todowrite",
            description: "Publish or update the visible task plan. Use for any multi-step work.",
            parameters: schema([
                "items": [
                    "type": "array",
                    "description": "List of {text, status}; status = pending | active | done | cancelled",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "status": ["type": "string"]
                        ],
                        "required": ["text"]
                    ]
                ]
            ], required: ["items"])
        ),
        ToolDefinition(
            name: "todo_read",
            description: "Read the current visible task plan.",
            parameters: schema([:], required: [])
        ),
        ToolDefinition(
            name: "git_status",
            description: "Show git status for the workspace.",
            parameters: schema([:], required: [])
        ),
        ToolDefinition(
            name: "git_diff",
            description: "Show git diff (working tree or staged).",
            parameters: schema(["staged": ["type": "boolean"]], required: [])
        ),
        ToolDefinition(
            name: "git_log",
            description: "Show recent commits.",
            parameters: schema(["limit": ["type": "integer", "description": "Default 10"]], required: [])
        ),
        ToolDefinition(
            name: "fs_grep",
            description: "Regex search inside files of a directory.",
            parameters: schema([
                "pattern": ["type": "string"],
                "path": ["type": "string", "description": "Directory, default '.'"],
                "glob": ["type": "string", "description": "Optional file glob, e.g. '*.swift'"]
            ], required: ["pattern"])
        ),
        ToolDefinition(
            name: "fs_glob",
            description: "Find files by glob pattern relative to the workspace.",
            parameters: schema(["pattern": ["type": "string"]], required: ["pattern"])
        ),
        ToolDefinition(
            name: "bash",
            description: "Run a shell command in the workspace and return stdout/stderr.",
            parameters: schema([
                "command": ["type": "string"],
                "timeout_ms": ["type": "integer", "description": "Default 60000"]
            ], required: ["command"])
        ),
        ToolDefinition(
            name: "webfetch",
            description: "LAST RESORT for static pages only, after scrapling and browser failed. Fetch a URL and return readable text (HTML stripped).",
            parameters: schema(["url": ["type": "string"]], required: ["url"])
        ),
        ToolDefinition(
            name: "websearch",
            description: "Search the web through DuckDuckGo and return titles, URLs and snippets.",
            parameters: schema(["query": ["type": "string"]], required: ["query"])
        ),
        ToolDefinition(
            name: "browser",
            description: "FALLBACK ONLY. Use MCP scrapling tools first; call this when scrapling failed or is unavailable. Headless Chromium via Playwright. Every action needs url. Actions: goto, open, text, html, click, fill, screenshot.",
            parameters: schema([
                "action": ["type": "string", "enum": ["goto", "open", "text", "html", "click", "fill", "screenshot"]],
                "url": ["type": "string"],
                "selector": ["type": "string"],
                "value": ["type": "string"],
                "path": ["type": "string", "description": "Screenshot output path"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "screenshot",
            description: "Capture the whole screen or a window to ~/HARNES_S_DATA/artifacts.",
            parameters: schema(["window_id": ["type": "integer"]], required: [])
        ),
        ToolDefinition(
            name: "ocr",
            description: "Extract text from an image file using the macOS Vision framework.",
            parameters: schema(["path": ["type": "string"]], required: ["path"])
        ),
        ToolDefinition(
            name: "index_workspace",
            description: "Index the workspace folder into searchable memory (text + embeddings). Run once, or after big changes.",
            parameters: schema([
                "path": ["type": "string", "description": "Folder to index, default the workspace"]
            ], required: [])
        ),
        ToolDefinition(
            name: "schedule_add",
            description: "Create a recurring task that sends a prompt on an interval (in minutes).",
            parameters: schema([
                "title": ["type": "string"],
                "prompt": ["type": "string"],
                "interval_minutes": ["type": "integer"]
            ], required: ["title", "prompt", "interval_minutes"])
        ),
        ToolDefinition(
            name: "schedule_list",
            description: "List scheduled recurring tasks.",
            parameters: schema([:], required: [])
        ),
        ToolDefinition(
            name: "schedule_remove",
            description: "Delete a scheduled task by id.",
            parameters: schema(["id": ["type": "integer"]], required: ["id"])
        ),
        ToolDefinition(
            name: "memory_add",
            description: "Save a durable fact to user memory.",
            parameters: schema([
                "text": ["type": "string"],
                "kind": ["type": "string", "description": "fact | decision | preference | pattern"]
            ], required: ["text"])
        ),
        ToolDefinition(
            name: "memory_search",
            description: "Full-text search over saved memory.",
            parameters: schema(["query": ["type": "string"]], required: ["query"])
        ),
        ToolDefinition(
            name: "secret_save",
            description: "Save a password or token under an alias in the local database.",
            parameters: schema([
                "alias": ["type": "string"],
                "value": ["type": "string"],
                "note": ["type": "string"]
            ], required: ["alias", "value"])
        ),
        ToolDefinition(
            name: "secret_get",
            description: "Read a saved secret by alias. Only when the user explicitly asks.",
            parameters: schema(["alias": ["type": "string"]], required: ["alias"])
        ),
        ToolDefinition(
            name: "secret_search",
            description: "Find saved secrets by alias or note fragment.",
            parameters: schema(["query": ["type": "string"]], required: ["query"])
        ),
        ToolDefinition(
            name: "skill_list",
            description: "List installed skills.",
            parameters: schema([:], required: [])
        ),
        ToolDefinition(
            name: "skill_install",
            description: "Install a skill from a local folder, a SKILL.md path, or a direct URL.",
            parameters: schema([
                "source": ["type": "string"],
                "force": ["type": "boolean"]
            ], required: ["source"])
        ),
        ToolDefinition(
            name: "mcp_list",
            description: "List configured MCP servers.",
            parameters: schema([:], required: [])
        )
    ]

    private static func schema(_ properties: [String: [String: Any]], required: [String]) -> [String: AnySendable] {
        [
            "type": AnySendable("object"),
            "properties": AnySendable(properties),
            "required": AnySendable(required)
        ]
}
}
