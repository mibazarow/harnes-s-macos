#if DEBUG
import Foundation

/// Fake transcripts used to produce README screenshots. Compiled only in Debug, and
/// only shown when `HARNESS_DEMO` names a scenario, so a normal Debug run is untouched.
///
/// The point is to show the real shape of a working session: a request, the tool calls
/// it caused, and an answer that reports what actually changed.
enum DemoTranscript {
    static var scenario: String? {
        ProcessInfo.processInfo.environment["HARNESS_DEMO"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static var messages: [ChatMessage]? {
        switch scenario {
        case "code": code
        case "memory": memory
        case "search": search
        case "git": git
        case "browser": browser
        case "markdown": markdown
        default: nil
        }
    }

    private static let day = Date()

    private static func trace(_ name: String, _ summary: String, error: Bool = false) -> ToolTrace {
        ToolTrace(name: name, summary: summary, isError: error, isRunning: false)
    }

    // MARK: - 1. Debugging a broken build

    private static var code: [ChatMessage] {
        [
            ChatMessage(
                role: .user,
                text: "Сборка падает на тестах после вчерашнего мержа. Глянь, что там?"
            ),
            ChatMessage(
                role: .assistant,
                text: """
                Тесты падают в `ContextComposerTests`: ждут 40 000 токенов хвоста, получают 12 000. Причина не в тесте, а в `tailBudget` — после мержа он считается от `window`, а не от `budget`.
                """,
                reasoning: """
                Сначала воспроизвожу. Без реального вывода `xcodebuild` любые догадки про \
                «наверное, там опционал» — гадание. Читаю последний коммит и запускаю тесты.
                """,
                tools: [
                    trace("git_log", "5 коммитов · HEAD 8aa787d"),
                    trace("bash", "xcodebuild test -only-testing:HarnessTests/ContextComposerTests"),
                    trace("fs_read", "Core/Agent/ContextComposer.swift · 1–180"),
                    trace("search_code", "\"tailBudget\" → 4 совпадения")
                ]
            ),
            ChatMessage(
                role: .assistant,
                text: """
                Нашёл. В `ContextComposer.swift:74` хвост считается от полного окна модели, а не от бюджета после системного промпта:

                ```diff
                - let tail = Int(Double(window) * minimumTailShare)
                + let tail = Int(Double(budget) * minimumTailShare)
                ```

                На окне 128 000 это давало хвост 40 000 вместо 12 000, и тест ловил расхождение. Поправил, прогнал весь набор.
                """,
                reasoning: """
                Вижу разницу: `tailBudget` берёт `window` (полное окно модели) вместо `budget` \
                (окно минус системный промпт и схемы инструментов). На большом окне разница \
                в 3 раза — ровно то, что показывает тест.
                """,
                tools: [
                    trace("edit_file", "ContextComposer.swift · 1 правка"),
                    trace("bash", "xcodebuild test · 137 тестов, 0 падений")
                ]
            ),
            ChatMessage(
                role: .user,
                text: "И почему он вообще зелёный был до мержа?"
            ),
            ChatMessage(
                role: .assistant,
                text: """
                Потому что тест сравнивал с `window`, а не с `budget`. Пока окно в фикстуре совпадало с бюджетом — оба выражения давали одно число, и ошибка была невидима. Мерж добавил второй набор схем инструментов, бюджет уменьшился, фикстура перестала маскировать разницу.

                Добавил в тест явный бюджет, отдельный от окна, — теперь такая регрессия падает сразу, а не через полгода.
                """,
                tools: [
                    trace("fs_write", "Tests/ContextComposerTests.swift · +18 строк"),
                    trace("bash", "xcodebuild test · 138 тестов, 1 пропущен")
                ]
            )
        ]
    }

    // MARK: - 2. Memory across sessions

    private static var memory: [ChatMessage] {
        [
            ChatMessage(
                role: .user,
                text: "Напомни, на чём мы остановились в прошлый раз и какой у нас стек?"
            ),
            ChatMessage(
                role: .assistant,
                text: """
                Вспомнил без пересказа истории.

                **Стек.** macOS 27+, Swift 6, SwiftUI + AppKit, GRDB поверх SQLite. Сборка через XcodeGen, зависимости — swift-markdown, swift-transformers, ONNX Runtime.

                **Где остановились.** Компакция переписана на структурированное саммари с хвостом по токенам; последний коммит — `8aa787d`. Открытым оставалось одно: одно сообщение больше всего бюджета всё ещё уходит целиком, и мы решили не резать его вслепую.

                Это три записи из памяти, все с датой и источником — их видно в `/memory`.
                """,
                reasoning: """
                Это запрос к памяти, а не к истории чата: история могла обнулиться, а \
                запомненные факты — нет. Ищу по смыслу, не по ключевым словам.
                """,
                tools: [
                    trace("memory_search", "стек проекта → 3 записи"),
                    trace("memory_search", "на чём остановились → 1 запись")
                ]
            ),
            ChatMessage(
                role: .user,
                text: "А пароль от тестового стенда не подскажешь?"
            ),
            ChatMessage(
                role: .assistant,
                text: """
                Он сохранён под алиасом `staging-db`, но в открытом виде я его не покажу — скажи «покажи пароль staging-db», и тогда достану.

                Заодно: сам пароль в память не попадал, он лежит отдельно от фактов, в таблице секретов, и в контекст модели без запроса не уходит.
                """,
                tools: [
                    trace("secret_list", "3 секрета · staging-db, prod-api, mail")
                ]
            )
        ]
    }

    // MARK: - 3. Finding code in a large workspace

    private static var search: [ChatMessage] {
        [
            ChatMessage(
                role: .user,
                text: "Где в проекте проверяется авторизация в Битриксе? Нужен файл, который дергает CheckAuthorization."
            ),
            ChatMessage(
                role: .assistant,
                text: """
                Точка входа — `local/php_interface/init.php:38`. Там `CheckAuthorization` вызывается один раз, дальше идёт `CMain::GetUser()` и проверка группы `ADMIN`.

                Рядом ещё три места, где права проверяются иначе:

                | Файл | Что делает |
                |---|---|
                | `local/php_interface/init.php:38` | `CheckAuthorization`, редирект на `/auth/` |
                | `local/components/sale.order/class.php:112` | проверка группы через `CUser::GetUserGroupList` |
                | `local/ajax/upload.php:9` | нет проверки вообще — принимает файл от любого |

                Последний стоит закрыть: он вызывается напрямую и не наследует проверку из компонента.
                """,
                reasoning: """
                Сначала по смыслу, потом точным поиском. Семантика найдёт «проверку прав», \
                даже если слова другие; точный поиск добьёт имена функций.
                """,
                tools: [
                    trace("index_workspace", "1 284 файла · 9 412 чанков · 14 с"),
                    trace("search_code", "авторизация битрикс → 8 совпадений"),
                    trace("search_code", "CheckAuthorization (точный) → 1 совпадение"),
                    trace("fs_read", "local/php_interface/init.php · 30–60")
                ]
            )
        ]
    }

    // MARK: - 4. Commit and push

    private static var git: [ChatMessage] {
        [
            ChatMessage(
                role: .user,
                text: "Закоммить и запушь. И не забудь, что у нас два зеркала."
            ),
            ChatMessage(
                role: .assistant,
                text: """
                Смотрю дифф — три файла, всё по делу, секретов нет. Коммичу и пушу в оба зеркала параллельно.
                """,
                reasoning: """
                Перед коммитом смотрю дифф целиком: в нём может оказаться лишнее, \
                например локальный конфиг или случайно попавший токен.
                """,
                tools: [
                    trace("git_status", "3 изменённых файла"),
                    trace("git_diff", "ContextComposer.swift · ContextComposerTests.swift · CHANGELOG.md"),
                    trace("git_commit", "fix: count the tail from the budget, not the window"),
                    trace("bash", "git push origin master && git push github master")
                ]
            ),
            ChatMessage(
                role: .assistant,
                text: """
                Готово, обе стороны на одном коммите `5452def`.

                - `origin` → `gitverse.ru/mibazarow/harnes-s-macos` — ok
                - `github` → `github.com/mibazarow/harbes-s-macos` — ok

                Оба пуша шли одновременно; если бы одна сторона упала, я бы сказал какая и почему, а не написал «запушено» на половину.
                """,
                tools: [
                    trace("bash", "git rev-parse master origin/master github/master → 1 общий хеш")
                ]
            )
        ]
    }

    // MARK: - 5. Web research with a table

    private static var browser: [ChatMessage] {
        [
            ChatMessage(
                role: .user,
                text: "Сравни цены на M4 Mac mini в трёх магазинах и скажи, где брать."
            ),
            ChatMessage(
                role: .assistant,
                text: """
                Собрал. Разница между лучшим и худшим предложением — 9 400 ₽, и она не про цену на сайте, а про доставку.

                | Магазин | Цена | Доставка | Итого |
                |---|---|---|---|
                | Ситилинк | 62 990 ₽ | самовывоз, 0 ₽ | **62 990 ₽** |
                | DNS | 64 499 ₽ | 2 дня, 0 ₽ | 64 499 ₽ |
                | М.Видео | 65 990 ₽ | 5 дней, 400 ₽ | 66 390 ₽ |

                Брать в Ситилинке, если пункт выдачи рядом: цена ниже на 1 509 ₽ при том же сроке. Переплата в DNS оправдана только если до Ситилинка ехать далеко.

                Цены на 7 ноября 2026, 00:40. Комплектация везде одна — 16 ГБ / 256 ГБ.
                """,
                reasoning: """
                Магазины отдают данные только через JS, curl получает заглушку. Значит, \
                браузер, а не webfetch. Три страницы — три параллельных открытия, чтобы \
                не ждать последовательно.
                """,
                tools: [
                    trace("browser", "ситилинк.ру → карточка M4 Mac mini"),
                    trace("browser", "dns-shop.ru → карточка M4 Mac mini"),
                    trace("browser", "mvideo.ru → карточка M4 Mac mini"),
                    trace("screenshot", "3 снимка в artifacts/")
                ]
            )
        ]
    }

    // MARK: - 6. Markdown showcase

    private static var markdown: [ChatMessage] {
        [
            ChatMessage(
                role: .user,
                text: "Покажи, как ты рендеришь ответ: код, таблицу, список, цитату."
            ),
            ChatMessage(
                role: .assistant,
                text: """
                Короткий ответ выглядит так: правка в `ContextComposer.swift`, коммит `8aa787d`, тестов 138.

                Список:

                1. Сначала читаю файл целиком, а не по кускам — иначе правка бьёт мимо контекста.
                2. Меняю одну вещь за раз, чтобы падение теста указывало на причину.
                3. Прогоняю весь набор, а не только затронутые тесты.

                Таблица:

                | Что | Было | Стало |
                |---|---|---|
                | Хвост | 40 000 | 12 000 |
                | Тесты | 1 падение | 0 падений |

                Код:

                ```swift
                let tail = Int(Double(budget) * minimumTailShare)
                ```

                Цитата:

                > Спецификация — документ. Код — реализация. Когда они расходятся, прав код, а документ переписывают.

                И встроенный код в строке: `git pushall` пушит в оба зеркала, `Esc` останавливает ответ.
                """
            )
        ]
    }
}
#endif
