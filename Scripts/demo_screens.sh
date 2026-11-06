#!/bin/bash
# Renders the README screenshots from the built-in demo transcripts.
#
#   Scripts/demo_screens.sh [outdir]
#
# Uses a throwaway data folder, so the real ~/HARNES_S_DATA is never touched.
# Each scenario is a Debug-only fake conversation (App/DemoTranscript.swift) that
# shows the real shape of a working session: the request, the tool calls it caused,
# and an answer that reports what changed.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1

out=${1:-DOCS/screenshots}
app=.build/Build/Products/Debug/Harness.app
data=/tmp/harness_demo_data


if [ ! -x "$app/Contents/MacOS/Harness" ]; then
    echo "Сначала собери Debug: xcodebuild ... -configuration Debug build" >&2
    exit 1
fi

mkdir -p "$out"

# A fresh data folder per run: the demo must not inherit real providers or memory.
pkill -f "$app/Contents/MacOS/Harness" 2>/dev/null || true
sleep 1
rm -rf "$data"

seed_provider() {
    local db="$data/database/harness.db"
    [ -f "$db" ] || return 0
    sqlite3 "$db" <<'SQL'
DELETE FROM providers;
INSERT INTO providers
    (id, name, base_url, api_key, models_json, default_model, context_window,
     is_default, health, created_at, updated_at)
VALUES
    ('demo', 'DeepSeek', 'https://api.deepseek.com/v1', 'demo',
     '["deepseek-v4.1-flash"]', 'deepseek-v4.1-flash', 800000,
     1, 'ok', datetime('now'), datetime('now'));
SQL
}

capture() {
    local name=$1

    osascript >/dev/null 2>&1 <<OSA || true
tell application "System Events" to tell process "Harness"
    set frontmost to true
    set position of window 1 to {40, 40}
    set size of window 1 to {1260, 900}
end tell
OSA
    sleep 2

    # Capture exactly the window: a fixed region would include the Dock on a
    # laptop screen, and macOS clamps the height to what fits.
    bounds=$(osascript -e 'tell application "System Events" to tell process "Harness" to get {position, size} of window 1' 2>/dev/null || echo "")
    if [ -n "$bounds" ]; then
        region=$(printf '%s' "$bounds" | tr -d ' ' | awk -F, '{print $1","$2","$3","$4}')
    else
        region="40,40,1260,900"
    fi

    # Click empty space below the last message (never a button), then scroll the
    # transcript to its first message: a screenshot that starts mid-answer looks broken.
    cliclick -w 120 "c:640,880" "kp:page-up" "kp:page-up" "kp:page-up" "kp:page-up" "kp:page-up" >/dev/null
    sleep 1

    screencapture -x -o -R"$region" "$out/$name.png"
    echo "  $name.png"
}

scenarios=(code memory search git browser markdown)

first=1
for i in "${!scenarios[@]}"; do
    scenario=${scenarios[$i]}
    HARNESS_DEMO="$scenario" HARNESS_DATA_DIR="$data" "$app/Contents/MacOS/Harness" >/dev/null 2>&1 &
    sleep 4
    if [ "$first" = 1 ]; then
        seed_provider
        first=0
        pkill -f "$app/Contents/MacOS/Harness" 2>/dev/null || true
        sleep 1
        HARNESS_DEMO="$scenario" HARNESS_DATA_DIR="$data" "$app/Contents/MacOS/Harness" >/dev/null 2>&1 &
        sleep 4
    fi
    capture "$scenario"
    pkill -f "$app/Contents/MacOS/Harness" 2>/dev/null || true
    sleep 1
done

echo "Готово: $out"
