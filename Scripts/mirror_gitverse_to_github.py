#!/usr/bin/env python3
"""Mirror public Gitverse repositories to GitHub.

Reads a TSV of `name<TAB>size_kb<TAB>default_branch<TAB>description`, creates a
public GitHub repository for every name that does not exist yet, then pushes a
full mirror (all branches and tags). Repositories that already exist on GitHub
are never touched.

Usage:
    Scripts/mirror_gitverse_to_github.py repos.tsv [--dry-run]
"""

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKEN_FILE = os.path.join(ROOT, "DOCS", "github-token.md")
OWNER = "mibazarow"
API = "https://api.github.com"
WORK = "/tmp/gv_mirror"
ACCEPT = "application/vnd.gitverse.object+json;version=1"


def read_token() -> str:
    with open(TOKEN_FILE, encoding="utf-8") as handle:
        text = handle.read()
    for line in text.splitlines():
        line = line.strip()
        if line.startswith(("ghp_", "github_pat_")):
            return line
    raise SystemExit("токен GitHub не найден в DOCS/github-token.md")


def api(method: str, path: str, token: str, payload: dict | None = None):
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(
        f"{API}{path}",
        data=data,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request) as response:
            body = response.read()
            return response.status, json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        body = error.read()
        try:
            parsed = json.loads(body)
        except json.JSONDecodeError:
            parsed = {"message": body.decode(errors="replace")[:300]}
        return error.code, parsed


def existing_repos(token: str) -> dict[str, int]:
    """Name -> size in KB. Zero means the repository exists but has no content yet."""
    repos: dict[str, int] = {}
    page = 1
    while True:
        status, data = api("GET", f"/user/repos?per_page=100&page={page}&affiliation=owner", token)
        if status != 200 or not data:
            raise SystemExit(f"не удалось получить список репозиториев GitHub: {status} {data}")
        for repo in data:
            repos[repo["name"].lower()] = repo.get("size") or 0
        if len(data) < 100:
            return repos
        page += 1


def has_commits(token: str, name: str) -> bool:
    """True when the GitHub repository already has at least one commit.

    The `size` field lags behind a push, so it cannot be used to tell "empty" from
    "already mirrored" right after the upload.
    """
    status, data = api("GET", f"/repos/{OWNER}/{name}/commits?per_page=1", token)
    return status == 200 and bool(data)


def run(command: list[str], env: dict[str, str] | None = None) -> tuple[int, str]:
    result = subprocess.run(
        command,
        capture_output=True,
        text=True,
        env=env,
        timeout=3600,
        check=False,
    )
    return result.returncode, (result.stdout + result.stderr).strip()


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    tsv = sys.argv[1]
    dry_run = "--dry-run" in sys.argv[2:]

    token = read_token()
    known = existing_repos(token)
    os.makedirs(WORK, exist_ok=True)

    rows = []
    with open(tsv, encoding="utf-8") as handle:
        for line in handle:
            line = line.rstrip("\n")
            if not line:
                continue
            name, size, branch, description = (line.split("\t") + ["", "", "", ""])[:4]
            rows.append((name, int(size or 0), branch or "master", description))

    rows.sort(key=lambda row: -row[1])

    env = dict(os.environ)
    env.update(
        GH_TOKEN=token,
        GIT_TERMINAL_PROMPT="0",
        GIT_ASKPASS="/usr/bin/true",
        GIT_SSH_COMMAND="ssh -o BatchMode=yes -o ConnectTimeout=20",
    )
    helper = "!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f"

    results = []
    for index, (name, size_kb, branch, description) in enumerate(rows, start=1):
        prefix = f"[{index}/{len(rows)}] {name}"
        if name.lower() in known and not dry_run and has_commits(token, name):
            print(f"{prefix}: уже есть на GitHub, пропуск", flush=True)
            results.append((name, "exists", ""))
            continue
        if dry_run:
            print(f"{prefix}: будет создан ({size_kb} КБ)", flush=True)
            results.append((name, "dry-run", ""))
            continue

        if name.lower() in known:
            print(f"{prefix}: репозиторий пуст, дозаливаю содержимое", flush=True)
        else:
            print(f"{prefix}: создаю репозиторий", flush=True)
            status, data = 0, None
            for attempt in range(12):
                status, data = api(
                    "POST",
                    "/user/repos",
                    token,
                    {
                        "name": name,
                        "description": description or None,
                        "private": False,
                        "has_issues": True,
                        "has_wiki": False,
                    },
                )
                if status in (200, 201):
                    break
                # Secondary rate limits clear on their own; hammering only extends them.
                if status in (403, 429):
                    print(
                        f"{prefix}: лимит GitHub, пауза 5 мин (попытка {attempt + 1}/12)",
                        flush=True,
                    )
                    time.sleep(300)
                    continue
                break
            if status not in (200, 201):
                print(f"{prefix}: GitHub отказал в создании: {status} {data}", flush=True)
                results.append((name, "create-failed", f"{status} {data}"))
                continue

        bare = os.path.join(WORK, f"{name}.git")
        run(["rm", "-rf", bare], env)
        print(f"{prefix}: клонирую с Gitverse", flush=True)
        code, output = run(["git", "clone", "--mirror", f"git@gitverse.ru:{OWNER}/{name}.git", bare], env)
        if code != 0:
            print(f"{prefix}: клон не удался: {output[:400]}", flush=True)
            results.append((name, "clone-failed", output[:400]))
            continue

        code, refs = run(["git", "-C", bare, "for-each-ref", "--count=1"], env)
        if code != 0 or not refs.strip():
            print(f"{prefix}: репозиторий пуст, коммитов нет", flush=True)
            results.append((name, "empty", ""))
            continue

        print(f"{prefix}: пушу в GitHub ({size_kb} КБ)", flush=True)
        code, output = run(
            [
                "git",
                "-C",
                bare,
                "-c",
                "credential.helper=",
                "-c",
                f"credential.helper={helper}",
                "push",
                "--mirror",
                f"https://github.com/{OWNER}/{name}.git",
            ],
            env,
        )
        if code != 0:
            print(f"{prefix}: пуш не удался: {output[:400]}", flush=True)
            results.append((name, "push-failed", output[:400]))
            continue

        print(f"{prefix}: готово", flush=True)
        results.append((name, "ok", ""))
        # Space out creations: a burst of them triggers GitHub's anti-abuse limit.
        time.sleep(15)
        # Keep the disk from filling up: the mirror is only needed until it is pushed.
        run(["rm", "-rf", bare], env)
        time.sleep(1)

    print("\n=== Итог ===", flush=True)
    counts: dict[str, int] = {}
    for name, state, detail in results:
        counts[state] = counts.get(state, 0) + 1
        if state not in ("ok", "exists"):
            print(f"  {state:14} {name} {detail[:120]}", flush=True)
    for state, count in sorted(counts.items()):
        print(f"  {state}: {count}", flush=True)
    return 0 if all(state in ("ok", "exists", "dry-run", "empty") for _, state, _ in results) else 1


if __name__ == "__main__":
    sys.exit(main())