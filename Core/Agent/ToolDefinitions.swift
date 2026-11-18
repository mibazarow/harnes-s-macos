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
            name: "fs_copy",
            description: "Copy a file or directory. Refuses to overwrite unless overwrite is true; dry_run reports the plan.",
            parameters: schema([
                "from": ["type": "string"], "to": ["type": "string"],
                "overwrite": ["type": "boolean"], "dry_run": ["type": "boolean"]
            ], required: ["from", "to"])
        ),
        ToolDefinition(
            name: "fs_move",
            description: "Move or rename a file or directory. Outside the workspace needs confirm: true.",
            parameters: schema([
                "from": ["type": "string"], "to": ["type": "string"],
                "overwrite": ["type": "boolean"], "confirm": ["type": "boolean"]
            ], required: ["from", "to"])
        ),
        ToolDefinition(
            name: "fs_mkdir",
            description: "Create a directory with intermediate parents.",
            parameters: schema(["path": ["type": "string"]], required: ["path"])
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
            description: "Edit by line range, regex or exact text; ambiguous matches are refused. Returns a diff.",
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
            description: "Search workspace code by meaning and keywords; uses the semantic index when present and falls back to scanning files.",
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
            name: "windows",
            exposure: .deferred,
            description: "On-screen windows (id for screenshot) or running apps; bounds in points and pixels. Also Spaces, Mission Control and Stage Manager.",
            parameters: schema([
                "action": ["type": "string", "enum": ["list", "apps", "move", "resize", "minimize", "close", "fullscreen", "to_display", "spaces", "move_to_space", "mission_control", "stage_manager"]],
                "app": ["type": "string", "description": "list: only this application"],
                "filter": ["type": "string", "description": "apps: name substring"],
                "id": ["type": "integer", "description": "Window id from list"],
                "x": ["type": "integer"], "y": ["type": "integer"],
                "w": ["type": "integer"], "h": ["type": "integer"],
                "display": ["type": "integer", "description": "to_display: index"],
                "value": ["type": "boolean", "description": "fullscreen/mission_control/stage_manager: on/off"],
                "space": ["type": "integer", "description": "move_to_space: space index or id"],
                "confirm": ["type": "boolean", "description": "move_to_space"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "shortcut",
            exposure: .deferred,
            description: "Run macOS Shortcuts by name (list, run, view); this is the text channel for Calendar, Mail and other app actions.",
            parameters: schema([
                "action": ["type": "string", "enum": ["list", "run", "view"]],
                "name": ["type": "string", "description": "Shortcut name"],
                "input": ["type": "string", "description": "Text passed as a file to run"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "app_script",
            exposure: .deferred,
            description: "Run AppleScript or JXA against an application dictionary (Safari, Finder, Mail). System Events is refused by TCC.",
            parameters: schema([
                "language": ["type": "string", "enum": ["applescript", "jxa"]],
                "source": ["type": "string", "description": "Script source"]
            ], required: ["source"])
        ),
        ToolDefinition(
            name: "ui",
            exposure: .deferred,
            description: "AX tree, search, press or focus by path; pixel fallback by image for canvas and games. Needs Accessibility; System Settings clicks need confirm.",
            parameters: schema([
                "action": ["type": "string", "enum": ["tree", "find", "click", "set_value", "focus", "menu_list", "menu_click"]],
                "app": ["type": "string", "description": "App name or bundle id; default frontmost"],
                "pid": ["type": "integer"],
                "depth": ["type": "integer", "description": "tree depth, default 3, max 8"],
                "max_nodes": ["type": "integer", "description": "tree budget, default 2000"],
                "query": ["type": "string", "description": "find: substring or regex"],
                "regex": ["type": "boolean"],
                "limit": ["type": "integer", "description": "find: matches, default 20"],
                "path": ["type": "array", "items": ["type": "integer"], "description": "Element path from tree or find"],
                "value": ["type": "string", "description": "set_value"],
                "path_titles": ["type": "array", "items": ["type": "string"], "description": "menu_click via path"],
                "image": ["type": "string", "description": "find/click: fragment PNG, template match in the window; ambiguous hits are refused"],
                "window_id": ["type": "integer", "description": "image: window to search, default the app's largest"],
                "threshold": ["type": "number", "description": "image: match threshold, default 0.85"],
                "confirm": ["type": "boolean", "description": "Required for System Settings actions"],
                "verify": ["type": "boolean", "description": "click: compare the element area before/after"],
                "expect_frontmost": ["type": "string", "description": "Abort if this app is not frontmost; nothing is sent"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "permissions",
            exposure: .deferred,
            description: "Check Accessibility and Screen Recording grants for this process and show the settings panel paths.",
            parameters: schema([:], required: [])
        ),
        ToolDefinition(
            name: "mouse",
            exposure: .deferred,
            description: "Move, click, drag or scroll the pointer in screen points. Needs the Accessibility grant.",
            parameters: schema([
                "action": ["type": "string", "enum": ["move", "click", "double_click", "right_click", "drag", "scroll"]],
                "x": ["type": "integer"], "y": ["type": "integer"],
                "to_x": ["type": "integer", "description": "drag target"],
                "to_y": ["type": "integer"],
                "dx": ["type": "integer", "description": "scroll pixels"],
                "dy": ["type": "integer"],
                "expect_frontmost": ["type": "string", "description": "Abort if this app is not frontmost"]
            ], required: ["action", "x", "y"])
        ),
        ToolDefinition(
            name: "files",
            exposure: .deferred,
            description: "List volumes with free space, eject a volume (confirm), mount or unmount a DMG.",
            parameters: schema([
                "action": ["type": "string", "enum": ["volumes", "eject", "dmg_mount", "dmg_unmount"]],
                "path": ["type": "string"], "name": ["type": "string", "description": "eject by volume name"],
                "confirm": ["type": "boolean", "description": "eject"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "apps",
            exposure: .deferred,
            description: "List running apps; open a file, URL or app; activate, hide or quit (quit needs confirm).",
            parameters: schema([
                "action": ["type": "string", "enum": ["list", "open", "activate", "hide", "quit"]],
                "target": ["type": "string", "description": "open: path or URL"],
                "path": ["type": "string", "description": "open: alias for target"],
                "app": ["type": "string", "description": "name or bundle id"],
                "pid": ["type": "integer"],
                "confirm": ["type": "boolean", "description": "quit"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "notify",
            exposure: .deferred,
            description: "Send a notification; read the Notification Center via AX; dismiss one or clear all (confirm). Private ones come back redacted.",
            parameters: schema([
                "action": ["type": "string", "enum": ["send", "read", "dismiss", "clear"]],
                "title": ["type": "string"], "body": ["type": "string"],
                "path": ["type": "array", "items": ["type": "integer"], "description": "dismiss: path from read"],
                "confirm": ["type": "boolean", "description": "Required for clear"]
            ], required: [])
        ),
        ToolDefinition(
            name: "clipboard",
            exposure: .deferred,
            description: "Read, write, list types or clear the system clipboard. Prefer write + keyboard combo cmd+v for long texts.",
            parameters: schema([
                "action": ["type": "string", "enum": ["read", "write", "types", "clear"]],
                "text": ["type": "string", "description": "For write"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "keyboard",
            exposure: .deferred,
            description: "Type Unicode text or press keys and combos in the frontmost app. Needs the Accessibility grant.",
            parameters: schema([
                "action": ["type": "string", "enum": ["type", "key", "combo"]],
                "text": ["type": "string", "description": "For type"],
                "key": ["type": "string", "description": "return, tab, escape, arrows, f1-f12"],
                "combo": ["type": "string", "description": "cmd+shift+4, ctrl+alt+delete"],
                "expect_frontmost": ["type": "string", "description": "Abort if this app is not frontmost"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "system",
            exposure: .deferred,
            description: "Machine state and grants: info, cpu, memory, thermal, power, disk, volumes, processes; permissions; tcc_panels.",
            parameters: schema([
                "action": ["type": "string", "enum": ["text", "permissions", "tcc_panels"]],
                "service": ["type": "string", "description": "tcc_panels: accessibility, screen_recording, full_disk_access, calendars, ..."],
                "sections": ["type": "array", "items": ["type": "string"],
                             "description": "info, cpu, memory, power, load, disk, volumes, processes; omit for all"],
                "path": ["type": "string", "description": "disk: top-5 largest folders here"]
            ], required: [])
        ),
        ToolDefinition(
            name: "process",
            exposure: .deferred,
            description: "Processes and background commands: run (returns an id), list, logs, wait, stop, ps, info, signal, kill_tree.",
            parameters: schema([
                "action": ["type": "string", "enum": ["run", "list", "logs", "stop", "wait", "ps", "info", "signal", "kill_tree"]],
                "command": ["type": "string", "description": "Shell command"],
                "cwd": ["type": "string", "description": "Default workspace"],
                "id": ["type": "string", "description": "id from run or list"],
                "pid": ["type": "integer", "description": "Process id for info, signal, kill_tree"],
                "signal": ["type": "string", "description": "TERM (default), KILL, HUP, INT"],
                "sort": ["type": "string", "enum": ["memory", "cpu", "pid"], "description": "ps order, default memory"],
                "limit": ["type": "integer", "description": "ps rows, default 20"],
                "lines": ["type": "integer", "description": "Lines, default 50"],
                "filter": ["type": "string", "description": "ps: name substring; logs: line substring"],
                "timeout_ms": ["type": "integer", "description": "wait timeout, default 30000"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "display",
            exposure: .deferred,
            description: "Displays: list, set_mode, arrangement, mirror, rotate, night_shift, restore_last; confirm.",
            parameters: schema([
                "action": ["type": "string", "enum": [
                    "list", "set_mode", "arrangement", "mirror", "rotate", "night_shift", "restore_last"
                ]],
                "display": ["type": "integer", "description": "Display index from list"],
                "width": ["type": "integer"], "height": ["type": "integer"],
                "refresh": ["type": "number", "description": "Preferred refresh, default the highest"],
                "x": ["type": "integer"], "y": ["type": "integer"],
                "master": ["type": "integer", "description": "mirror: master display index"],
                "degrees": ["type": "integer", "description": "rotate: 0 | 90 | 180 | 270"],
                "value": ["type": ["boolean", "number", "string"],
                          "description": "mirror on/off; night_shift on/off/0..100"],
                "on": ["type": "boolean", "description": "night_shift: alias for value"],
                "confirm": ["type": "boolean", "description": "Required for mutations"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "power",
            exposure: .deferred,
            description: "Power and sound: status, sleep, lock, caffeinate, brightness, volume, mute, media, audio, restart.",
            parameters: schema([
                "action": ["type": "string", "enum": [
                    "status", "sleep", "lock", "display_off", "caffeinate", "low_power",
                    "brightness", "volume", "mute", "media", "audio", "restart", "shutdown"
                ]],
                "value": ["type": ["integer", "string", "boolean"],
                          "description": "0..100, on/off, 0/1, or a media command"],
                "display": ["type": "integer", "description": "brightness: display index, default 0"],
                "device": ["type": "string", "description": "audio: device name substring; omit to list"],
                "id": ["type": "integer", "description": "audio: device id"],
                "direction": ["type": "string", "enum": ["output", "input"]],
                "input": ["type": "boolean", "description": "mute: the microphone"],
                "seconds": ["type": "integer", "description": "caffeinate: default 300, max 3600"],
                "off": ["type": "boolean", "description": "caffeinate off: release assertions"],
                "confirm": ["type": "boolean", "description": "restart/shutdown"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "network",
            exposure: .deferred,
            description: "Network in one call: ports, interfaces, DNS, ping, HTTP status, Wi-Fi, Bonjour discovery, VPN, proxy.",
            parameters: schema([
                "action": ["type": "string", "enum": ["ports", "interfaces", "dns", "ping", "http", "wifi", "discover", "vpn", "proxy"]],
                "port": ["type": "integer", "description": "ports: filter by port number"],
                "filter": ["type": "string", "description": "ports: process or address substring"],
                "host": ["type": "string", "description": "dns and ping target"],
                "url": ["type": "string", "description": "http target"],
                "method": ["type": "string", "description": "http method, default GET"],
                "count": ["type": "integer", "description": "ping packets, default 3"],
                "timeout_ms": ["type": "integer", "description": "ping timeout, default 5000"],
                "ssid": ["type": "string", "description": "wifi: join this network (needs confirm and password)"],
                "password": ["type": "string", "description": "wifi: never logged"],
                "scan": ["type": "boolean", "description": "wifi: list visible networks"],
                "value": ["type": ["boolean", "string"], "description": "wifi radio on/off; vpn restart; proxy on/off"],
                "types": ["type": "array", "items": ["type": "string"], "description": "discover: services, default ssh/http/smb/ipp"],
                "service": ["type": "string", "description": "proxy: network service, default Wi-Fi"],
                "confirm": ["type": "boolean", "description": "wifi join, vpn restart, proxy set"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "watch",
            exposure: .deferred,
            description: "Wait for file system changes instead of polling: subscribe to a path for N ms and return what changed. FSEvents, read-only.",
            parameters: schema([
                "path": ["type": "string", "description": "Path or comma-separated paths, default workspace"],
                "duration_ms": ["type": "integer", "description": "Wait window, default 5000, max 120000"],
                "limit": ["type": "integer", "description": "Max lines, default 30"]
            ], required: [])
        ),
        ToolDefinition(
            name: "spotlight",
            exposure: .deferred,
            description: "Search the whole machine through the Spotlight index by file name, outside the workspace. Returns path, size, date, kind.",
            parameters: schema([
                "query": ["type": "string", "description": "File name substring"],
                "scope": ["type": "string", "description": "home (default), computer, network or an absolute path"],
                "limit": ["type": "integer", "description": "Max results, default 20"]
            ], required: ["query"])
        ),
        ToolDefinition(
            name: "activity",
            exposure: .deferred,
            description: "Audit trail: list steps by day, show one, export CSV for a range, prune older than 30 days.",
            parameters: schema([
                "action": ["type": "string", "enum": ["list", "show", "export", "prune"]],
                "id": ["type": "integer", "description": "show: action id"],
                "limit": ["type": "integer", "description": "list: default 40"],
                "from": ["type": "string", "description": "export: ISO date"],
                "to": ["type": "string", "description": "export: ISO date"],
                "confirm": ["type": "boolean", "description": "Required for prune"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "skill_learn",
            exposure: .deferred,
            description: "Procedures you write for yourself: save, patch one quote, list, read. Secrets scrubbed; hand-edited files locked.",
            parameters: schema([
                "action": ["type": "string", "enum": ["save", "patch", "list", "read"]],
                "name": ["type": "string", "description": "Lowercase latin, digits, dashes"],
                "description": ["type": "string", "description": "One line, up to 200 characters"],
                "body": ["type": "string", "description": "Procedure steps, up to 6000 characters"],
                "old": ["type": "string", "description": "patch: exact quote to replace"],
                "new": ["type": "string", "description": "patch: replacement"],
                "source_message_id": ["type": "string", "description": "The user's message that started the task"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "observe",
            exposure: .deferred,
            description: "Watch activity as metadata only (app, kind, key, point), summarise, record and replay a macro with confirm. Never records text.",
            parameters: schema([
                "action": ["type": "string", "enum": [
                    "status", "start", "stop", "summary", "clear",
                    "record_start", "record_stop", "replay"
                ]],
                "gap_seconds": ["type": "integer", "description": "summary: pause that closes a segment, default 5"],
                "path": ["type": "string", "description": "replay: macro file"],
                "confirm": ["type": "boolean", "description": "Required for replay"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "share",
            exposure: .deferred,
            description: "Mail and AirDrop: compose opens a letter, send needs confirm, airdrop opens the picker, services lists names.",
            parameters: schema([
                "action": ["type": "string", "enum": ["compose", "send", "airdrop", "services"]],
                "to": ["type": "array", "items": ["type": "string"], "description": "Recipients"],
                "subject": ["type": "string"], "body": ["type": "string"],
                "attachments": ["type": "array", "items": ["type": "string"]],
                "paths": ["type": "array", "items": ["type": "string"], "description": "airdrop files"],
                "confirm": ["type": "boolean", "description": "Required for send"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "contacts",
            exposure: .deferred,
            description: "Address book via Contacts: search by name, phone or email, get one card, create or update (confirm). Limited access shows only chosen cards.",
            parameters: schema([
                "action": ["type": "string", "enum": ["search", "get", "create", "update"]],
                "query": ["type": "string", "description": "search: name, phone or email"],
                "id": ["type": "string", "description": "get/update: contact identifier"],
                "given_name": ["type": "string"], "family_name": ["type": "string"],
                "organization": ["type": "string"],
                "phones": ["type": "array", "items": ["type": "string"]],
                "emails": ["type": "array", "items": ["type": "string"]],
                "note": ["type": "string"],
                "limit": ["type": "integer", "description": "search: default 10"],
                "confirm": ["type": "boolean", "description": "create/update"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "calendar",
            exposure: .deferred,
            description: "Calendar and reminders: events, create/update/delete (confirm, own events only), calendars, free_busy, reminders. ISO-8601 dates.",
            parameters: schema([
                "action": ["type": "string", "enum": [
                    "events", "create_event", "update_event", "delete_event", "calendars",
                    "free_busy", "reminders", "create_reminder", "complete_reminder"
                ]],
                "id": ["type": "string", "description": "Event or reminder identifier"],
                "title": ["type": "string"],
                "start": ["type": "string", "description": "ISO-8601, e.g. 2026-11-19T10:00:00+03:00"],
                "end": ["type": "string", "description": "ISO-8601; default start + duration"],
                "due": ["type": "string", "description": "Reminder due, ISO-8601"],
                "from": ["type": "string", "description": "Range start, ISO-8601"],
                "to": ["type": "string", "description": "Range end, ISO-8601"],
                "duration": ["type": "integer", "description": "Minutes, default 60"],
                "calendar": ["type": "string", "description": "Calendar title substring"],
                "location": ["type": "string"], "notes": ["type": "string"],
                "alarm_minutes": ["type": "integer", "description": "Alarm N minutes before"],
                "recurrence": ["type": "string", "enum": ["daily", "weekly", "monthly"]],
                "all_day": ["type": "boolean"],
                "limit": ["type": "integer"],
                "confirm": ["type": "boolean", "description": "Required for delete_event"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "settings",
            exposure: .deferred,
            description: "Shell and appearance: appearance, wallpaper, dock, menu_bar, hot_corners, focus, screensaver, accessibility; confirm.",
            parameters: schema([
                "action": ["type": "string", "enum": [
                    "appearance", "wallpaper", "dock", "menu_bar", "hot_corners",
                    "focus", "screensaver", "accessibility"
                ]],
                "value": ["type": "string", "description": "dark|light|auto; dock knob; corner; invert|zoom|cursor"],
                "setting": ["type": "string", "description": "dock setting, corner action, on/off"],
                "path": ["type": "string", "description": "wallpaper file or solid:#RRGGBB"],
                "size": ["type": "integer", "description": "accessibility cursor size 1..4"],
                "shortcut": ["type": "string", "description": "focus: shortcut name, default Set Focus"],
                "confirm": ["type": "boolean", "description": "Required for mutations"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "launchd",
            exposure: .deferred,
            description: "Login item, launch agents, Time Machine status, manual start, list, exclusions.",
            parameters: schema([
                "action": ["type": "string", "enum": [
                    "login_item", "agents", "tm_status", "tm_start", "tm_list", "tm_exclusions"
                ]],
                "value": ["type": ["boolean", "string"],
                          "description": "login_item on/off; tm_exclusions add/remove/check"],
                "filter": ["type": "string", "description": "agents: label substring"],
                "limit": ["type": "integer", "description": "agents default 60, tm_list default 20"],
                "path": ["type": "string", "description": "tm_exclusions target"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "workspace",
            exposure: .deferred,
            description: "Project root for relative paths, git and search. set needs a path and confirm.",
            parameters: schema([
                "action": ["type": "string", "enum": ["get", "set", "list"]],
                "path": ["type": "string", "description": "set: absolute path or ~/..."],
                "confirm": ["type": "boolean", "description": "Required for set"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "task",
            exposure: .core,
            description: "Delegate a self-contained job to a fresh subagent. Returns only its final answer; pass paths you already found so it does not search again.",
            parameters: schema([
                "prompt": ["type": "string", "description": "Full self-contained instruction"],
                "read_only": ["type": "boolean", "description": "true = investigation only, no edits"],
                "paths": ["type": "array", "items": ["type": "string"], "description": "Files or folders to include verbatim so the subagent does not search again"]
            ], required: ["prompt"])
        ),
        ToolDefinition(
            name: "todowrite",
            exposure: .core,
            description: "Publish, update or complete the visible plan: items replaces, update patches, complete ticks. 1-based.",
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
            name: "git",
            exposure: .deferred,
            description: "Git: status, fetch, pull, push (confirm), branch, switch, merge, show, blame, conflicts; destructive forms refused.",
            parameters: schema([
                "action": ["type": "string", "enum": ["status", "fetch", "pull", "push", "branch", "switch", "merge", "show", "blame", "conflicts"]],
                "cwd": ["type": "string", "description": "Repository path, default workspace"],
                "name": ["type": "string", "description": "branch/switch/merge target"],
                "from": ["type": "string", "description": "branch start point"],
                "ref": ["type": "string", "description": "show: ref, default HEAD"],
                "path": ["type": "string", "description": "blame: file"],
                "confirm": ["type": "boolean", "description": "push"],
                "force": ["type": "boolean", "description": "Ignored: force operations are refused"]
            ], required: ["action"])
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
            description: "Search with ripgrep: matches with context, count per file, outline of headings and declarations.",
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
            description: "Run a shell command in the workspace. Output is cut to 2000 characters (full: true → 8000) and says how much was left; narrow the command.",
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
            description: "LAST RESORT for static pages, after scrapling and browser failed. Readable text without nav/footer/scripts; supports pagination.",
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
            description: "Persistent Chromium with a saved profile: tabs and logins live between calls. For logged-in sites, clicks, forms and network inspection.",
            parameters: schema([
                "action": ["type": "string", "enum": [
                    "goto", "open", "text", "html", "click", "fill", "screenshot",
                    "list", "tabs", "switch", "back", "forward", "reload", "wait",
                    "eval", "network", "state"
                ]],
                "url": ["type": "string", "description": "goto/open"],
                "selector": ["type": "string", "description": "click, fill, wait"],
                "value": ["type": "string", "description": "fill text"],
                "path": ["type": "string", "description": "screenshot/state file"],
                "index": ["type": "integer", "description": "switch: tab index"],
                "expression": ["type": "string", "description": "eval: JS"],
                "timeout_ms": ["type": "integer"],
                "reload": ["type": "boolean", "description": "network: reload first"],
                "mode": ["type": "string", "enum": ["save", "load"], "description": "state"]
            ], required: ["action"])
        ),
        ToolDefinition(
            name: "screenshot",
            exposure: .deferred,
            description: "Capture the screen, a window (even if covered), or a rectangle; returns the file path for image_read/ocr.",
            parameters: schema([
                "window_id": ["type": "integer"],
                "window": ["type": "string", "description": "Window title substring; resolved to id"],
                "scale_down": ["type": "number", "description": "0..1 multiplier"],
                "max_height": ["type": "integer", "description": "Resample so height fits"],
                "clip": [
                    "type": "object",
                    "properties": [
                        "x": ["type": "integer"], "y": ["type": "integer"],
                        "width": ["type": "integer"], "height": ["type": "integer"]
                    ]
                ],
                "save_to": ["type": "string", "description": "Output path, .png added if missing"],
                "stream": ["type": "boolean", "description": "Watch the window for changes instead of one frame"],
                "duration_ms": ["type": "integer", "description": "stream: default 3000, max 15000"],
                "interval_ms": ["type": "integer", "description": "stream: default 500, min 200"]
            ], required: [])
        ),
        ToolDefinition(
            name: "ocr",
            exposure: .deferred,
            description: "Extract text via Vision. coords=true adds pixel boxes; hit=true adds centres in screen points.",
            parameters: schema([
                "path": ["type": "string"],
                "lang": ["type": "array", "items": ["type": "string"], "description": "Languages, default [ru, en]"],
                "coords": ["type": "boolean", "description": "Include pixel bounding boxes"],
                "hit": ["type": "boolean", "description": "Add centre of each box in screen points"],
                "display": ["type": "integer", "description": "hit: display index when the size does not identify it"],
                "window_id": ["type": "integer", "description": "hit: the capture is this window"]
            ], required: ["path"])
        ),
        ToolDefinition(
            name: "doc_read",
            exposure: .deferred,
            description: "Read pdf (page range), docx, xlsx, pptx, odt, rtf, text; use it instead of fs_read for these.",
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
            description: "Inspect or transform an image or PDF page (EXIF, crop, rotate, resize); returns a PNG the chat can show.",
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
            description: "Save a durable fact: stable preferences, conventions, decisions, corrections. Not task state, file contents, secrets, or unconfirmed guesses.",
            parameters: schema([
                "text": ["type": "string", "description": "One self-contained fact, without pronouns"],
                "kind": ["type": "string", "description": "fact | decision | preference | pattern"],
                "area": ["type": "string", "description": "about | preferences | people | routines | lessons | decision | fact"],
                "quote": ["type": "string", "description": "Verbatim fragment of the user's message"],
                "source_message_id": ["type": "string", "description": "Optional id of the user's message"],
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
            description: "Read a saved secret by alias. Masked by default; reveal=true sends it to the provider in this chat.",
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
            description: "Load full schemas of deferred tools for the rest of the session.",
            parameters: schema([
                "names": ["type": "array", "items": ["type": "string"],
                          "description": "Tool names, for example [\"screenshot\", \"doc_read\"]"]
            ], required: ["names"])
        ),
        ToolDefinition(
            name: "mcp_tools",
            exposure: .deferred,
            description: "MCP tools: omit args to list servers and tools; pass server; pass server+tool for the JSON schema.",
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
