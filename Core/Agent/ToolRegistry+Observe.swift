import Foundation

extension ToolRegistry {
    /// R27.2: observe, never record text. The summary answers "где я был и что делал",
    /// which is what a polite assistant needs before it clicks anything.
    func observeTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? "status"
        let observer = InputObserver.shared

        switch action {
        case "status":
            var text = "running: \(observer.isRunning ? "yes" : "no") events=\(observer.count)"
            if let error = observer.lastError { text += "\nlast_error: \(error)" }
            return .ok(text)

        case "start":
            guard observer.start() else {
                return .fail(observer.lastError ?? "Наблюдение не запустилось.")
            }
            return .ok("Наблюдение запущено: только метаданные (приложение, тип, клавиша, точка), "
                + "без текста набора. Остановить: observe stop.")

        case "stop":
            observer.stop()
            return .ok("Наблюдение остановлено, событий было \(observer.count).")

        case "clear":
            observer.clear()
            return .ok("Буфер наблюдения очищен.")

        case "summary":
            let gap = Double(Self.int(args, "gap_seconds") ?? 5)
            let segments = ActivitySummary.segments(observer.snapshot(), gap: gap)
            return .ok(ActivitySummary.text(segments))

        case "record_start":
            observer.beginRecording()
            return .ok("Запись макроса начата (только клики и клавиши, без текста).")

        case "record_stop":
            let steps = observer.endRecording()
            guard !steps.isEmpty else { return .ok("Запись пуста: ни одного действия.") }
            let url = AppPaths.artifactsDirectory
                .appendingPathComponent("macro-\(Int(Date().timeIntervalSince1970)).json")
            try? AppPaths.ensureDirectory(AppPaths.artifactsDirectory)
            guard let data = try? JSONEncoder().encode(steps) else {
                return .fail("Макрос не сериализуется.")
            }
            do {
                try data.write(to: url)
            } catch {
                return .fail("Макрос не записан: \(error.localizedDescription)")
            }
            return .ok("Макрос записан: \(url.path) шагов=\(steps.count). "
                + "Повтор — observe replay с confirm.")

        case "replay":
            guard Self.bool(args, "confirm") ?? false else {
                return .fail("observe replay требует confirm: true: макрос нажимает за человека.")
            }
            guard let raw = args["path"] as? String else {
                return .fail("path обязателен: файл макроса из artifacts.")
            }
            let url = resolve(raw)
            guard let data = try? Data(contentsOf: url),
                  let steps = try? JSONDecoder().decode([ObservedEvent].self, from: data) else {
                return .fail("Макрос не прочитан: \(display(url))")
            }
            let (done, stopped) = await observer.replay(steps)
            return .ok("Макрос выполнен: \(done)/\(steps.count) шагов"
                + (stopped ? ", остановлен аварийным стопом." : "."))

        default:
            return .fail("action: status | start | stop | summary | clear | record_start | record_stop | replay")
        }
    }
}
