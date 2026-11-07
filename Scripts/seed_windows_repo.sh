#!/bin/bash
# Builds a clean starting folder for the Windows repository.
#
#   Scripts/seed_windows_repo.sh ~/harnes-s-windows
#
# The folder is meant to be copied to a Windows machine: it has no Swift sources,
# no Xcode project, no git history and no tokens — only the specification, the
# visual reference, fonts, skills and the machine-readable contract.
set -euo pipefail

cd "$(dirname "$0")/.." || exit 1
root=$(pwd)

dest=${1:-}
if [ -z "$dest" ]; then
    echo "Использование: Scripts/seed_windows_repo.sh <путь-назначения>" >&2
    exit 2
fi
dest=$(cd "$(dirname "$dest")" 2>/dev/null && pwd)/$(basename "$dest")

if [ -e "$dest" ] && [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
    echo "Папка $dest уже существует и не пуста. Укажи новую." >&2
    exit 1
fi

mkdir -p "$dest"/{docs,packaging/assets/fonts,shared-seed/skills,src/Harness.App,src/Harness.Core,src/Harness.Core.Tests}

echo "  документация"
cp WINDOWS_PORT.md "$dest/docs/WINDOWS_PORT.md"
cp ВОСПРОИЗВОДИМОЕ_ТЕХНИЧЕСКОЕ_ЗАДАНИЕ.md "$dest/docs/ARCHITECTURE-macOS.md"
cp -R DOCS/screenshots "$dest/docs/screenshots"

echo "  шрифты"
cp Resources/Fonts/*.ttf "$dest/packaging/assets/fonts/"
cp Resources/Fonts/LICENSE* "$dest/packaging/assets/fonts/" 2>/dev/null || true

echo "  скиллы"
if [ -d "$HOME/HARNES_S_DATA/config/skills" ]; then
    cp -R "$HOME/HARNES_S_DATA/config/skills/." "$dest/shared-seed/skills/"
elif [ -d Resources/skills/builtin ]; then
    cp -R Resources/skills/builtin/. "$dest/shared-seed/skills/"
fi
find "$dest/shared-seed" -name ".DS_Store" -delete

echo "  контракт"
binary=.build/Build/Products/Debug/Harness.app/Contents/MacOS/Harness
if [ -x "$binary" ]; then
    "$binary" --export-contracts "$dest/contract.json" >/dev/null
else
    echo "    Debug-сборки нет, контракт не сгенерирован."
    echo "    Собери Debug и повтори, либо принеси contract.json с собой." >&2
fi

echo "  служебные файлы"
cat > "$dest/.gitignore" <<'EOF'
bin/
obj/
.vs/
*.user
*.suo
TestResults/
publish/
*.msix
*.msixupload
*.pfx
.DS_Store
Thumbs.db

# Локальные секреты: у каждой машины свой токен, в репозиторий не попадает
DOCS/github-token.md
secrets/
EOF

cat > "$dest/README.md" <<'EOF'
# HARNES-S для Windows

Нативный ИИ-агент и чат-ассистент для Windows 11: один чат, одна память, работа с файлами,
тестами и git в том же разговоре. Порт macOS-версии, отдельная кодовая база.

## Что здесь лежит

- `docs/WINDOWS_PORT.md` — как это строится: стек, контракт, этапы, риски.
- `docs/ARCHITECTURE-macOS.md` — спецификация поведения macOS-версии, эталон.
- `docs/screenshots/` — как это выглядит.
- `contract.json` — имена и схемы 46 инструментов, версия схемы БД, хеш промпта.
- `shared-seed/skills/` — скиллы, которые ставятся в папку данных при первом запуске.
- `packaging/assets/fonts/` — Nordwand Mono (MIT).

## Сборка

```powershell
dotnet restore Harness.sln
dotnet build Harness.sln -c Debug
dotnet test  src/Harness.Core.Tests
dotnet run   --project src/Harness.App
```

Подробности — в `docs/WINDOWS_PORT.md`.
EOF

cat > "$dest/AGENTS.md" <<'EOF'
# AGENTS.md — HARNES-S для Windows

Нативное приложение Windows 11 на C# / .NET 10 / WinUI 3. Папка данных —
`%USERPROFILE%\HARNES_S_DATA\`, никогда не внутри репозитория.

## Правила

- `Harness.Core` не ссылается на `Microsoft.UI.Xaml`. UI получает данные через модели и события.
- Контракт с macOS-версией зафиксирован в `contract.json`; менять имена и схемы инструментов
  можно только вместе с обновлением этого файла.
- Секреты в репозиторий не попадают; токены лежат в `DOCS/` и игнорируются git.
- Пуш идёт в два зеркала параллельно: `git pushall`.

## Сборка и тесты

```powershell
dotnet build Harness.sln -c Debug
dotnet test  src/Harness.Core.Tests
```
EOF

echo
echo "Готово: $dest"
echo "Дальше: скопировать папку на Windows-машину, затем git init и два remote."
du -sh "$dest" | awk '{print "Размер: "$1}'