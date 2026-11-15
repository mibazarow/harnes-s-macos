# R14 — задание для нового агента

Прочитай `R14_TASK.md` целиком: там диагноз, замеры, требования и порядок работ. Ниже —
технические координаты, чтобы не искать их заново.

## Где что лежит

| что | файл |
|---|---|
| вызов границы задачи после ответа | `Models/ChatStore.swift:382-385` |
| `recordTaskBoundary`, `compactAfterOverflow`, `compactIfMeasuredHot`, `prepareWindow`-обвязка | `Models/ChatStore+Compaction.swift` (62-77, 199-250, 316-350) |
| сам прунер | `Core/Agent/ToolOutputPruner.swift` (все 84 строки) |
| место, где подставляются заглушки | `Models/ChatStore+Compaction.swift:335-346` (`buildHistory`) |
| бюджет окна и `plan` | `Core/Agent/ContextComposer.swift:162+` |
| стоимость tool-трафика | `Core/Agent/ToolCost.swift` |
| константы режимов | `Core/Agent/Tuning.swift` (`toolOutputPruning`, `taskBoundarySummaryMessages`) |
| тесты | `Tests/ToolPruningTests.swift`, `Tests/CompactionPolicyTests.swift` |
| журнал, куда писать события | `latency.log`, через `ChatStore.logLatency` |

## Как проверить, что прунер вообще что-то делает

Быстрее всего — прочитать `~/HARNES_S_DATA/database/harness.db`, таблица `messages`,
колонка `exchanges` (JSON-массив вызовов с полем `output`). Готовый пробник лежит в
`Scripts/prune_probe.py` (воспроизводит логику `ToolOutputPruner` на реальной истории,
считает экономию через `json.dumps`). Запуск: `python3 Scripts/prune_probe.py`.

Ожидаемое поведение исправленного кода на этой истории (12 447 сообщений):
при `cutoff`, равном сообщению 11100, должно найтись 271 кандидат и ~5 300 реальных
токенов экономии. Сейчас находится 0.

## Сборка и тесты

```bash
cd /Users/mb/Documents/hdd_camouf_ru/MY_PET_PROJECTS/harnes-s-macos
xcodegen generate
xcodebuild -project Harness.xcodeproj -scheme Harness -configuration Debug \
  -derivedDataPath .build -destination 'platform=macOS' test
```

Текущее состояние: 342 теста, 0 падений. Критерий прунинга «экономия пачки» тестами
покрыт не был — добавить до правок, чтобы было видно регрессию.

## Границы

- Код инструментов (потолки вывода, сохранение в базу) — R14.5/R14.6, отдельным коммитом,
  после того как прунер начнёт работать.
- `compact()` и `CompactionService.summarize` в R14 не трогать.
- Баг-репорт по агенту дописывать в `TASK_AGENT_FIXES.md`, а не в `R14_TASK.md`.
