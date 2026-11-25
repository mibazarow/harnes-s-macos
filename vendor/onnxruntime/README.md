# ONNX Runtime, vendored

Локальная копия `microsoft/onnxruntime-swift-package-manager` @ `b7fb7f7`
(«Update ORT to 1.24.2», тег `v1.24.2`). Нужна, потому что 18.11.2026 upstream
исчез с GitHub: `microsoft/onnxruntime` и `microsoft/onnxruntime-swift-package-manager`
оба отдают 404. Хост `download.onnxruntime.ai`, откуда пакет качал бинарь, TLS
больше не поднимает. Подробности и обоснование — `TASKS.md`, пункт R32.

`project.yml` подключает это как `.package(path:)`, SwiftPM ничего не скачивает.

## Что внутри и чем отличается от upstream

| файл / папка | происхождение |
|---|---|
| `Package.swift` | upstream, изменён (см. ниже) |
| `objectivec/` | upstream без изменений |
| `onnxruntime.xcframework` | из `pod-archive-onnxruntime-c-1.24.2.zip`, только macOS-слайс |
| `LICENSE`, `LICENSE-ORT.txt` | MIT, Microsoft |

Правки в `Package.swift`:

- `binaryTarget` смотрит на локальный `onnxruntime.xcframework` вместо `url:`;
- убран продукт и таргет `onnxruntime_extensions` — приложение его никогда не
  линковало, а это 57 МБ;
- убраны тестовые таргеты: им нужны модели и ресурсы, в приложении они не нужны;
- платформа только `.macOS(.v14)`, iOS-слайсы выброшены.

Слайс переименован из `macos-arm64_x86_64` в `macos-arm64`, `Info.plist`
xcframework переписан под одну библиотеку. Бинарь ужат до `arm64` через
`lipo -extract arm64`: проект собирается с `ARCHS: arm64`,
`ONLY_ACTIVE_ARCH: YES`. 87 МБ → 39 МБ.

## Если понадобится обновить версию

Обновляться неоткуда: репозитория нет, `download.onnxruntime.ai` молчит.
Единственные источники — чужие форки и зеркала, а это supply-chain риск (в
обсуждении на HN уже нашли зеркало с несовпадающим sha256). Прежде чем менять,
сверять sha256 бинаря с официальным.

Целостность текущей копии:

```
sha256 (macos-arm64/onnxruntime.framework/Versions/A/onnxruntime) =
  063403cd4f0668a66dc4404b068aff81c50d5d7bf56030669fe0b17cb6d28bfc
```

Полная git-история upstream (58 МБ, все теги до `v1.19.2`, HEAD `b7fb7f7`)
сохранена вне репозитория: `~/HARNES_S_DATA/vendor-archive/onnxruntime-swift-package-manager.git`.
Оттуда можно восстановить любую другую версию, если понадобится.

## Как проверить, что работает

```
xcodebuild -project Harness.xcodeproj -scheme Harness -derivedDataPath .build \
  -destination 'platform=macOS' test -only-testing:HarnessTests/LocalEmbedderTests
```

Тесты должны пройти, а не уйти в `XCTSkip`: skip означает, что модель не
установлена, а не что ONNX сломан. Семантический поиск проверяется отдельно —
`memory_search` не должен падать в `lexical_only`.
