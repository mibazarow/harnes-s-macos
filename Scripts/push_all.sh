#!/bin/bash
# Pushes the current branch to every mirror at once.
#
#   origin  — Gitverse (git@gitverse.ru:mibazarow/harnes-s-macos.git)
#   github  — GitHub   (https://github.com/mibazarow/harbes-s-macos.git)
#
# Both run in parallel; the script fails if either side fails, so a half-pushed
# state is loud instead of silent. The GitHub token comes from
# DOCS/github-token.md through the credential helper, never from this script.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

branch=$(git rev-parse --abbrev-ref HEAD)
log=$(mktemp -t pushall)
trap 'rm -f "$log"' EXIT

pids=()
names=()

for remote in origin github; do
    git remote get-url "$remote" >/dev/null 2>&1 || continue
    git push "$remote" "$branch" >"$log.$remote" 2>&1 &
    pids+=($!)
    names+=("$remote")
done

status=0
for i in "${!pids[@]}"; do
    if wait "${pids[$i]}"; then
        printf '  %-7s ok  %s\n' "${names[$i]}" "$(git remote get-url "${names[$i]}")"
    else
        status=1
        printf '  %-7s FAILED\n' "${names[$i]}"
        sed 's/^/          /' "$log.${names[$i]}" | tail -20
    fi
    rm -f "$log.${names[$i]}"
done

exit "$status"
