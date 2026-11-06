#!/usr/bin/env python3
"""Install external skill folders into the app's user skills directory.

Usage:
    python3 Scripts/install_skills.py SOURCE_DIR [SOURCE_DIR ...]
    python3 Scripts/install_skills.py --dest DIR SOURCE_DIR ...

Default destination is ~/HARNES_S_DATA/config/skills, the directory HARNES-S
reads at runtime. Skills are not compiled into the app bundle.

Only SKILL.md frontmatter is rewritten; every other file in a skill folder is
copied verbatim.

GSD skills are skipped unless --include-gsd is passed: they can only run with the
external GSD Core runtime installed at ~/.config/kilo/gsd-core.
"""

import argparse
import pathlib
import re
import shutil

HOME = pathlib.Path.home()
DEFAULT_DEST = HOME / "HARNES_S_DATA" / "config" / "skills"

PATH_REPLACEMENTS = [
    (str(HOME / "Documents/MAMP/scrapper.mcp/.venv"), "<scrapling-venv>"),
    (str(HOME / "Documents/MCP_SERVERS_LOCAL/scrapper.mcp/.venv"), "<scrapling-venv>"),
    (str(HOME / ".venv-scraper"), "<playwright-venv>"),
    (str(HOME / ".kilocode/skills"), "<skills-dir>"),
    (str(HOME / ".config/kilo"), "<agent-config>"),
    (str(HOME), "~"),
]

SKILL_PATH_RE = (
    re.escape(str(HOME))
    + r"/\.(?:kilocode|claude)/skills/{name}|"
    + re.escape(str(HOME))
    + r"/\.config/kilo/skills/{name}"
)

SKIP_DIRS = {".git", "__pycache__", ".DS_Store", "node_modules"}
TEXT_SUFFIXES = {
    ".md", ".txt", ".py", ".sh", ".json", ".yaml", ".yml", ".csv",
    ".html", ".js", ".ts", ".css", ".xml", ".toml",
}


def parse_frontmatter(lines):
    """Return (metadata, body_start) for a simple YAML frontmatter block."""
    if not lines or lines[0].strip() != "---":
        return {}, 0
    try:
        close = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        return {}, 0

    metadata = {}
    key = None
    block_lines = []
    block_style = None

    def flush():
        nonlocal block_lines, block_style, key
        if key is None:
            return
        if block_style == ">":
            metadata[key] = " ".join(part.strip() for part in block_lines if part.strip())
        elif block_style == "|":
            metadata[key] = "\n".join(block_lines).strip()
        block_lines = []
        block_style = None
        key = None

    for raw in lines[1:close]:
        if key and block_style:
            if raw.startswith((" ", "\t")) or not raw.strip():
                block_lines.append(raw)
                continue
            flush()

        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("- "):
            continue
        match = re.match(r"^([A-Za-z0-9_.-]+):\s*(.*)$", raw)
        if not match:
            continue
        name, value = match.group(1).lower(), match.group(2).strip()
        if value in (">", "|", ">-", "|-", ">+", "|+"):
            key, block_style = name, value[0]
            continue
        if value == "":
            key = None
            continue
        metadata[name] = unquote(value)

    flush()
    return metadata, close + 1


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        inner = value[1:-1]
        if value[0] == '"':
            inner = inner.replace('\\"', '"').replace("\\n", " ")
        return inner
    return value


def collapse(text):
    return re.sub(r"\s+", " ", text).strip()


GSD_RUNTIME_RELATIVE = "HARNES_S_DATA/config/gsd/gsd-core"
GSD_RUNTIME = f"~/{GSD_RUNTIME_RELATIVE}"

GSD_PREAMBLE = f"""
# Running this skill inside HARNES-S

This workflow comes from GSD Core and was written for a slash-command agent. Adapt it to this app:

- Invoke it by loading this skill and treating `<arguments>` as the text the user typed after the skill name.
- Every `{GSD_RUNTIME}/...` path is required reading. Open it with `fs_read` before starting, and follow any further `@` includes inside those files the same way.
- There are no named subagent types. When the workflow says to spawn `gsd-<role>`, call the `task` tool with a self-contained prompt that includes the role file `{GSD_RUNTIME}/agents/<role>.md` (read it with `fs_read`).
- There is no `question` tool. Ask the user directly in chat and offer numbered options in plain text.
- Tool mapping: Read -> `fs_read`, Write -> `fs_write`, Edit -> `edit_file`, Bash -> `bash`, Glob -> `fs_glob`, Grep -> `fs_grep`, TodoWrite -> `todowrite`, Task -> `task`.
- The runtime is Node.js: `node {GSD_RUNTIME}/bin/gsd-tools.cjs <command>`. If the runtime is missing, tell the user GSD Core is not installed.
- GSD state lives in the project's `.planning/` directory.
"""


def sanitize(text, skill_name=None):
    if skill_name and skill_name.startswith("gsd-"):
        text = text.replace("@$HOME/.config/kilo/gsd-core", GSD_RUNTIME)
        text = text.replace("$HOME/.config/kilo/gsd-core", GSD_RUNTIME)
        text = text.replace("~/.config/kilo/gsd-core", GSD_RUNTIME)
        text = text.replace("@$HOME", "$HOME")
    if skill_name:
        text = re.sub(SKILL_PATH_RE.format(name=re.escape(skill_name)), "<skill-dir>", text)
    for old, new in PATH_REPLACEMENTS:
        text = text.replace(old, new)
    return text


GSD_RUNTIME_REPLACEMENTS = [
    ("$HOME/.config/kilo/gsd-core", "~/" + GSD_RUNTIME_RELATIVE),
    ("~/.config/kilo/gsd-core", "~/" + GSD_RUNTIME_RELATIVE),
    (str(HOME / ".config/kilo/gsd-core"), "~/" + GSD_RUNTIME_RELATIVE),
]


def install_gsd_runtime(config_dir: pathlib.Path, dest_root: pathlib.Path):
    """Copy gsd-core plus its sibling scripts into the data directory."""
    target = dest_root.parent / "gsd"
    target.mkdir(parents=True, exist_ok=True)

    for name in ("gsd-core", "scripts"):
        source = config_dir / name
        if not source.is_dir():
            raise SystemExit(f"missing GSD runtime part: {source}")
        out = target / name
        if out.exists():
            shutil.rmtree(out)
        shutil.copytree(source, out, ignore=shutil.ignore_patterns(*SKIP_DIRS))

    changed = 0
    for path in target.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        updated = text
        for old, new in GSD_RUNTIME_REPLACEMENTS:
            updated = updated.replace(old, new)
        if updated != text:
            path.write_text(updated, encoding="utf-8")
            changed += 1

    print(f"GSD runtime installed into {target} (patched {changed} files)")
    return target


def copy_skill(source: pathlib.Path, dest_root: pathlib.Path):
    name = source.name
    manifest_path = source / "SKILL.md"
    text = manifest_path.read_text(encoding="utf-8", errors="replace")
    lines = text.replace("\r\n", "\n").split("\n")
    meta, body_start = parse_frontmatter(lines)

    description = collapse(meta.get("description", ""))
    if not description:
        print(f"  skip {name}: no description")
        return None

    version = meta.get("version") or "1.0.0"
    license_name = meta.get("license")

    target = dest_root / name
    if target.exists():
        shutil.rmtree(target)
    target.mkdir(parents=True)

    for entry in source.rglob("*"):
        if any(part in SKIP_DIRS for part in entry.relative_to(source).parts):
            continue
        rel = entry.relative_to(source)
        if rel == pathlib.Path("SKILL.md"):
            continue
        out = target / rel
        if entry.is_dir():
            out.mkdir(parents=True, exist_ok=True)
            continue
        out.parent.mkdir(parents=True, exist_ok=True)
        if entry.suffix.lower() in TEXT_SUFFIXES:
            try:
                out.write_text(sanitize(entry.read_text(encoding="utf-8"), name), encoding="utf-8")
            except UnicodeDecodeError:
                shutil.copy2(entry, out)
        else:
            shutil.copy2(entry, out)

    body = sanitize("\n".join(lines[body_start:]), name).strip()
    if name.startswith("gsd-"):
        body = GSD_PREAMBLE.strip() + "\n\n---\n\n" + body
    header = ["---", f"name: {name}", f"description: {description}", f"version: {version}"]
    if license_name:
        header.append(f"license: {license_name}")
    header.append("---")
    (target / "SKILL.md").write_text("\n".join(header) + "\n\n" + body + "\n", encoding="utf-8")
    return name, description


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dest", default=str(DEFAULT_DEST), help="destination skills directory")
    parser.add_argument("--include-gsd", action="store_true", help="also install gsd-* skills")
    parser.add_argument("--gsd-runtime", help="agent config dir containing gsd-core and scripts")
    parser.add_argument("sources", nargs="+", help="skill folders or directories containing them")
    args = parser.parse_args(argv[1:])

    dest = pathlib.Path(args.dest).expanduser()
    sources = []
    for raw in args.sources:
        base = pathlib.Path(raw).expanduser()
        if not base.is_dir():
            print(f"not a directory: {base}")
            continue
        if (base / "SKILL.md").exists():
            sources.append(base)
        else:
            sources.extend(sorted(p for p in base.iterdir() if p.is_dir()))

    dest.mkdir(parents=True, exist_ok=True)

    if args.gsd_runtime:
        install_gsd_runtime(pathlib.Path(args.gsd_runtime).expanduser(), dest)

    imported = []
    for source in sources:
        if source.name.startswith("gsd-") and not args.include_gsd:
            continue
        if not (source / "SKILL.md").exists():
            continue
        result = copy_skill(source, dest)
        if result:
            imported.append(result)
            print(f"  {result[0]}: {result[1][:90]}")

    print(f"\nInstalled {len(imported)} skills into {dest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(__import__("sys").argv))
