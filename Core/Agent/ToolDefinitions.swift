import Foundation

/// Tool catalog: JSON schemas sent to the model. Kept separate from the
/// implementation so `ToolRegistry.swift` stays navigable.
extension ToolRegistry {
    static let definitions: [ToolDefinition] = [
        ToolDefinition(
            name: "fs_list",
            exposure: .core,
            description: "List files in a directory. Relative paths resolve against the workspace.",
            parameters: schema(["path": ["type": "string", "description": "Directory path, default '.'"]], required: [])
        ),
        ToolDefinition(
            name: "fs_read",
            exposure: .core,
            description: "Read a UTF-8 text file with line numbers.",
            parameters: schema([
                "path": ["type": "string", "description": "File path"],
                "offset": ["type": "integer", "description": "First line, 1-based"],
                "limit": ["type": "integer", "description": "Max lines, default 400"]
            ], required: ["path"])
        ),
        ToolDefinition(
            name: "fs_write",
            exposure: .core,
            description: "Create or overwrite a file with the given content.",
            parameters: schema([
                "path": ["type": "string"],
                "content": ["type": "string"]
            ], required: ["path", "content"])
        ),
        ToolDefinition(
            name: "edit_file",
            exposure: .core,
            description: "Edit by line range (start/end), regex (pattern) or exact text (old_text). Ambiguous matches are refused. Returns a diff of what changed.",
            parameters: schema([
                "path": ["type": "string"],
                "start": ["type": "integer", "description": "First line to replace, 1-based"],
                "end": ["type": "integer", "description": "Last line to replace, inclusive (default start)"],
                "pattern": ["type": "string", "description": "Regex to replace instead of line range"],
                "old_text": ["type": "string", "description": "Exact text to replace"],
                "new_text": ["type": "string"],
                "replace_all": ["type": "boolean", "description": "Replace every match, default false"]
            ], required: ["path", "new_text"])
        ),
        ToolDefinition(
            name: "apply_patch",
            description: "Apply a unified diff to one or more files. Preferred over full rewrites for multi-line edits.",
            parameters: schema([
                "path": ["type": "string", "description": "File the patch applies to"],
                "patch": ["type": "string", "description": "Unified diff with @@ hunks"],
                "patch_file": ["type": "string", "description": "Read the diff from this file instead of patch"]
            ], required: ["path"])
        ),
        ToolDefinition(
            name: "read_many",
            description: "Read several files in one call. Returns each file with line numbers; the reply says what was cut and which offset continues it.",
            parameters: schema([
                "paths": ["type": "array", "items": ["type": "string"]],
                "offset": ["type": "integer", "description": "First line in every file, 1-based"],
                "limit": ["type": "integer", "description": "Max lines per file, default 200"]
            ], required: ["paths"])
        ),
        ToolDefinition(
            name: "project_overview",
            exposure: .deferred,
            description: "Detect the project stack and return its build, test and lint commands. Pass path to inspect an attached folder.",
            parameters: schema(["path": ["type": "string", "description": "Folder, default the workspace"]], required: [])
        ),
        ToolDefinition(
            name: "search_code",
            exposure: .deferred,
            description: "Search the workspace code by meaning and by keywords. Uses the semantic index when it exists and falls back to scanning files when it does not, so indexing is optional.",
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
            exposure: .deferred,
            description: "Stash or pop working tree changes.",
            parameters: schema(["action": ["type": "string", "enum": ["push", "pop", "list"]]], required: ["action"])
        ),
        ToolDefinition(
            name: "fs_tree",
            exposure: .deferred,
            description: "Show a compact directory tree (depth-limited), skipping noise folders.",
            parameters: schema([
                "path": ["type": "string"],
                "depth": ["type": "integer", "description": "Default 4, max 8"]
            ], required: [])
        ),
        ToolDefinition(
            name: "trash_paths",
            exposure: .deferred,
            description: "Move files or folders to the app trash (reversible). Use instead of rm.",
            parameters: schema(["paths": ["type": "array", "items": ["type": "string"]]], required: ["paths"])
        ),
        ToolDefinition(
            name: "undo_list",
            exposure: .deferred,
            description: "List trashed items that can be restored.",
            parameters: schema([:], required: [])
        ),
        ToolDefinition(
            name: "restore_trashed",
            exposure: .deferred,
            description: "Restore an item from the app trash by its id.",
            parameters: schema(["id": ["type": "integer"]], required: ["id"])
        ),
        ToolDefinition(
            name: "file_versions",
            exposure: .deferred,
            description: "List saved versions of a file that were snapshotted before edits.",
            parameters: schema(["path": ["type": "string"]], required: ["path"])
        ),
        ToolDefinition(
            name: "restore_version",
            exposure: .deferred,
            description: "Restore a file to a previously snapshotted version.",
            parameters: schema([
                "path": ["type": "string"],
                "version": ["type": "string", "description": "stored_at from file_versions"]
            ], required: ["path", "version"])
        ),
        ToolDefinition(
            name: "task",
            exposure: .core,
            description: "Delegate a self-contained job to a fresh subagent with its own context. Returns only its final answer. Pass paths to hand over files or folders you already found, so the subagent does not search for them again.",
            parameters: schema([
                "prompt": ["type": "string", "description": "Full self-contained instruction"],
                "read_only": ["type": "boolean", "description": "true = investigation only, no edits"],
                "paths": ["type": "array", "items": ["type": "string"], "description": "Files or folders to include verbatim so the subagent does not search again"]
            ], required: ["prompt"])
        ),
        ToolDefinition(
            name: "todowrite",
            exposure: .core,
            description: "Publish, update or complete the visible plan. Full replace with items; point update with update; quick tick with complete. Indices are 1-based.",
            parameters: schema([
                "items": [
                    "type": "array",
                    "description": "Full list of {text, status, evidence}; replaces the plan",
                    "items": [
                        "type": "object",
                        "properties": [
                            "text": ["type": "string"],
                            "status": ["type": "string", "enum": ["pending", "active", "done", "cancelled"]],
                            "evidence": ["type": "string"]
                        ],
                        "required": ["text"]
                    ]
                ],
                "update": [
                    "type": "array",
                    "description": "Point updates, e.g. 3 -> done with evidence",
                    "items": [
                        "type": "object",
                        "properties": [
                            "index": ["type": "integer"],
                            "status": ["type": "string"],
                            "evidence": ["type": "string"]
                        ],
                        "required": ["index"]
                    ]
                ],
                "complete": ["type": "array", "items": ["type": "integer"], "description": "1-based indices to mark done"]
            ], required: [])
        ),
        ToolDefinition(
            name: "todo_read",
            exposure: .core,
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
            exposure: .deferred,
            description: "Show recent commits.",
            parameters: schema(["limit": ["type": "integer", "description": "Default 10"]], required: [])
        ),
        ToolDefinition(
            name: "fs_grep",
            exposure: .core,
            description: "Search with ripgrep. mode=matches shows lines with context, count totals per file, outline returns only headings and declarations (a cheap map of the code).",
            parameters: schema([
                "pattern": ["type": "string"],
                "path": ["type": "string", "description": "Directory or file, default '.'"],
                "glob": ["type": "string", "description": "Optional file glob, e.g. '*.swift'"],
                "mode": ["type": "string", "enum": ["matches", "count", "outline"], "description": "Default matches"],
                "ignore_case": ["type": "boolean"],
                "literal": ["type": "boolean", "description": "Treat pattern as plain text"],
                "before": ["type": "integer", "description": "Context lines before a match (0-10)"],
                "after": ["type": "integer", "description": "Context lines after a match (0-20)"],
                "limit": ["type": "integer", "description": "Max result lines, default 100"]
            ], required: ["pattern"])
        ),
        ToolDefinition(
            name: "fs_glob",
            exposure: .deferred,
            description: "Find files by glob pattern relative to the workspace.",
            parameters: schema(["pattern": ["type": "string"]], required: ["pattern"])
        ),
        ToolDefinition(
            name: "bash",
            exposure: .core,
            description: "Run a shell command in the workspace. Output is cut to 2000 characters by default (full: true raises it to 8000) and the reply says how much was left. Narrow the command instead of asking for everything.",
            parameters: schema([
                "command": ["type": "string"],
                "timeout_ms": ["type": "integer", "description": "Default 60000"],
                "max_chars": ["type": "integer", "description": "Output cap in characters, default 2000, max 8000"],
                "full": ["type": "boolean", "description": "Raise the cap to 8000"]
            ], required: ["command"])
        ),
        ToolDefinition(
            name: "webfetch",
            exposure: .deferred,
            description: "LAST RESORT for static pages only, after scrapling and browser failed. Extracts readable text (drops nav, footer, scripts, duplicate lines) and supports pagination.",
            parameters: schema([
                "url": ["type": "string"],
                "offset": ["type": "integer", "description": "Skip this many characters, default 0"],
                "limit": ["type": "integer", "description": "Max characters, default 30000"]
            ], required: ["url"])
        ),
        ToolDefinition(
            name: "websearch",
            exposure: .deferred,
            description: "Search the web through DuckDuckGo and return titles, URLs and snippets.",
            parameters: schema(["query": ["type": "string"]], required: ["query"])
        ),
        ToolDefinition(
            name: "browser",
            exposure: .deferred,
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
            exposure: .deferred,
            description: "Capture the screen, a window, or a rectangle; returns the file path for image_read/ocr.",
            parameters: schema([
                "window_id": ["type": "integer"],
                "clip": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "integer"], "y": ["type": "integer"],
                        "width": ["type": "integer"], "height": ["type": "integer"]
                    ]
                ],
                "save_to": ["type": "string", "description": "Output path, .png added if missing"]
            ], required: [])
        ),
        ToolDefinition(
            name: "ocr",
            exposure: .deferred,
            description: "Extract text from an image with the macOS Vision framework. coords=true also returns pixel bounding boxes for clicking.",
            parameters: schema([
                "path": ["type": "string"],
                "lang": ["type": "array", "items": ["type": "string"], "description": "Languages, default [ru, en]"],
                "coords": ["type": "boolean", "description": "Include pixel bounding boxes"]
            ], required: ["path"])
        ),
        ToolDefinition(
            name: "doc_read",
            exposure: .deferred,
            description: "Read a document by extension: pdf (page range), docx, xlsx, pptx, odt, rtf, and plain text/markdown. Use it instead of fs_read for these formats.",
            parameters: schema([
                "path": ["type": "string"],
                "page_from": ["type": "integer", "description": "PDF first page, 1-based"],
                "page_to": ["type": "integer", "description": "PDF last page, inclusive"],
                "formulas": ["type": "boolean", "description": "XLSX: return formulas instead of cached values"],
                "offset": ["type": "integer", "description": "For plain text: first line"],
                "limit": ["type": "integer", "description": "For plain text: max lines"]
            ], required: ["path"])
        ),
        ToolDefinition(
            name: "doc_write",
            exposure: .deferred,
            description: "Build a document from markdown. Supported extensions: docx, rtf, pdf, html, md, txt.",
            parameters: schema([
                "path": ["type": "string", "description": "Output file, extension decides the format"],
                "content": ["type": "string", "description": "Markdown source"],
                "source": ["type": "string", "description": "Or a path to a markdown file"]
            ], required: ["path"])
        ),
        ToolDefinition(
            name: "app_logs",
            exposure: .deferred,
            description: "Read the app's own log files (latency, MCP, cleanup) with filters, without bash.",
            parameters: schema([
                "name": ["type": "string", "description": "One log file, default all *.log"],
                "level": ["type": "string", "description": "Case-insensitive substring filter"],
                "since": ["type": "string", "description": "ISO8601 or relative span like 30m, 2h, 1d"],
                "limit": ["type": "integer", "description": "Max lines from the end, default 200"]
            ], required: [])
        ),
        ToolDefinition(
            name: "image_read",
            exposure: .deferred,
            description: "Inspect or transform an image or a PDF page (EXIF orientation, crop, rotate, resize) and return a PNG the chat can display. No external tools needed.",
            parameters: schema([
                "path": ["type": "string", "description": "Image or PDF"],
                "page": ["type": "integer", "description": "PDF page, default 1"],
                "info": ["type": "boolean", "description": "Only report size and orientation"],
                "width": ["type": "integer", "description": "Target width, keeps aspect"],
                "height": ["type": "integer", "description": "Target height, keeps aspect"],
                "scale_down": ["type": "integer", "description": "Shrink only if wider than this"],
                "crop_x": ["type": "integer"], "crop_y": ["type": "integer"],
                "crop_w": ["type": "integer"], "crop_h": ["type": "integer"],
                "rotate": ["type": "integer", "description": "Degrees clockwise"]
            ], required: ["path"])
        ),
        ToolDefinition(
            name: "index_workspace",
            exposure: .deferred,
            description: "Index the workspace folder into searchable memory (text + embeddings). Run once, or after big changes.",
            parameters: schema([
                "path": ["type": "string", "description": "Folder to index, default the workspace"]
            ], required: [])
        ),
        ToolDefinition(
            name: "schedule_add",
            exposure: .deferred,
            description: "Schedule a prompt: repeat every N minutes, or fire once at an absolute time.",
            parameters: schema([
                "title": ["type": "string"],
                "prompt": ["type": "string"],
                "interval_minutes": ["type": "integer", "description": "Repeat every N minutes"],
                "at": ["type": "string", "description": "One-shot ISO8601 time, e.g. 2026-11-15T15:00:00Z"]
            ], required: ["title", "prompt"])
        ),
        ToolDefinition(
            name: "schedule_list",
            exposure: .deferred,
            description: "List scheduled recurring tasks.",
            parameters: schema([:], required: [])
        ),
        ToolDefinition(
            name: "schedule_remove",
            exposure: .deferred,
            description: "Delete a scheduled task by id.",
            parameters: schema(["id": ["type": "integer"]], required: ["id"])
        ),
        ToolDefinition(
            name: "memory_add",
            exposure: .core,
            description: "Save a durable fact to user memory. Use for stable preferences, project conventions, decisions and corrections the user makes. Do not save one-off task state, things readable from files, secrets (use secret_save) or anything the user did not confirm.",
            parameters: schema([
                "text": ["type": "string", "description": "One self-contained fact, without pronouns"],
                "kind": ["type": "string", "description": "fact | decision | preference | pattern"],
                "pinned": ["type": "boolean", "description": "true when the user asked to remember this explicitly"]
            ], required: ["text"])
        ),
        ToolDefinition(
            name: "memory_forget",
            exposure: .core,
            description: "Delete saved memory by id, or by text query when the user asks to forget something.",
            parameters: schema([
                "query": ["type": "string", "description": "Memory id or text describing what to forget"]
            ], required: ["query"])
        ),
        ToolDefinition(
            name: "memory_list",
            exposure: .core,
            description: "List saved memory records with ids, so you can point at or delete a specific one.",
            parameters: schema([:], required: [])
        ),
        ToolDefinition(
            name: "memory_search",
            exposure: .core,
            description: "Full-text search over saved memory.",
            parameters: schema(["query": ["type": "string"]], required: ["query"])
        ),
        ToolDefinition(
            name: "secret_save",
            exposure: .deferred,
            description: "Save a password or token under an alias in the local database.",
            parameters: schema([
                "alias": ["type": "string"],
                "value": ["type": "string"],
                "note": ["type": "string"]
            ], required: ["alias", "value"])
        ),
        ToolDefinition(
            name: "secret_get",
            exposure: .deferred,
            description: "Read a saved secret by alias. By default the value stays masked; reveal=true returns it and sends it to the provider in this conversation.",
            parameters: schema([
                "alias": ["type": "string"],
                "reveal": ["type": "boolean", "description": "false (default) = mask, true = return the value"]
            ], required: ["alias"])
        ),
        ToolDefinition(
            name: "secret_search",
            exposure: .deferred,
            description: "Find saved secrets by alias or note fragment.",
            parameters: schema(["query": ["type": "string"]], required: ["query"])
        ),
        ToolDefinition(
            name: "skill_list",
            exposure: .deferred,
            description: "List installed skills.",
            parameters: schema([:], required: [])
        ),
        ToolDefinition(
            name: "skill_read",
            exposure: .deferred,
            description: "Load a skill's instructions, or one bundled file with `file`. The manifest's allowed-tools is enforced for the rest of the turn.",
            parameters: schema([
                "name": ["type": "string"],
                "file": ["type": "string", "description": "Relative path inside the skill, e.g. references/report.md"],
                "offset": ["type": "integer", "description": "Continue a long body from this character offset"]
            ], required: ["name"])
        ),
        ToolDefinition(
            name: "skill_install",
            exposure: .deferred,
            description: "Install a skill from a local folder, a SKILL.md path, or a URL. URL installs preview first and need confirm: true.",
            parameters: schema([
                "source": ["type": "string"],
                "force": ["type": "boolean"],
                "confirm": ["type": "boolean", "description": "Required for URL sources after reviewing the preview"]
            ], required: ["source"])
        ),
        ToolDefinition(
            name: "skill_remove",
            exposure: .deferred,
            description: "Remove an installed skill by name. Built-in skills are read-only.",
            parameters: schema(["name": ["type": "string"]], required: ["name"])
        ),
        ToolDefinition(
            name: "mcp_list",
            exposure: .deferred,
            description: "List configured MCP servers.",
            parameters: schema([:], required: [])
        ),
        ToolDefinition(
            name: "tool_load",
            exposure: .core,
            description: "Return the full argument schemas for tools listed as deferred and keep them for the rest of the session.",
            parameters: schema([
                "names": ["type": "array", "items": ["type": "string"],
                          "description": "Tool names, for example [\"screenshot\", \"doc_read\"]"]
            ], required: ["names"])
        ),
        ToolDefinition(
            name: "mcp_tools",
            exposure: .deferred,
            description: "Inspect MCP tools. Omit arguments to list all servers and tools; pass server to list one server; pass server and tool to get the full JSON schema.",
            parameters: schema([
                "server": ["type": "string", "description": "Server name; omit for all servers"],
                "tool": ["type": "string", "description": "Tool name; requires server"]
            ], required: [])
        )
    ]

    private static func schema(_ properties: [String: [String: Any]], required: [String]) -> [String: AnySendable] {
        [
            "type": AnySendable("object"),
            "properties": AnySendable(properties),
            "required": AnySendable(required)
        ]
    }

    /// Cost of the whole catalog in context tokens, not characters.
    ///
    /// Schemas are sent with every request, so their size is a permanent tax on the
    /// context window and on the cached prefix. Measuring with the same estimator the
    /// context plan uses keeps the number comparable to the budget instead of a
    /// chars/4 guess.
    /// Cost of the catalog exactly as this run sends it, MCP tools included.
    func schemaTokenCost() async -> Int {
        ToolCost.catalog(await schemas())
    }

    static func schemasTokenCost(_ definitions: [ToolDefinition] = ToolRegistry.definitions) -> Int {
        ToolCost.catalog(definitions)
    }

}
