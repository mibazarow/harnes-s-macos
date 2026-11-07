# AGENTS.md — HARNES-S

Native macOS Swift AI agent app. Data folder is `~/HARNES_S_DATA/`, never inside the repo.

## Pushing

The repo has two mirrors and they must stay identical:

| remote | URL |
|---|---|
| `origin` | `git@gitverse.ru:mibazarow/harnes-s-macos.git` |
| `github` | `https://github.com/mibazarow/harnes-s-macos.git` |

When the user asks to push, push to **both, in parallel**:

```bash
git pushall          # alias for Scripts/push_all.sh
```

Never push to one side only. If one side fails, say which one and why.

The GitHub token lives in `DOCS/github-token.md` (gitignored, mode 0600) and is read
by `/Users/mb/.config/github/credential-helper.sh`. Never print it, never commit it.

## Build and test

```bash
xcodegen generate
xcodebuild -project Harness.xcodeproj -scheme Harness -configuration Debug \
  -derivedDataPath .build -destination 'platform=macOS' test
```

Release install:

```bash
xcodebuild -project Harness.xcodeproj -scheme Harness -configuration Release \
  -derivedDataPath .build -destination 'platform=macOS' build
codesign --verify --deep --strict .build/Build/Products/Release/Harness.app
pkill -f "/Applications/Harness.app/Contents/MacOS/Harness"
rm -rf /Applications/Harness.app && cp -R .build/Build/Products/Release/Harness.app /Applications/
xattr -dr com.apple.quarantine /Applications/Harness.app
```
