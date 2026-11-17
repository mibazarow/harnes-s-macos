import Darwin
import Foundation

extension ToolRegistry {
    /// R19.3: process inspection without a shell.
    ///
    /// The daily "who is on this port / why is it stuck / kill it" loop used to be
    /// `pgrep` + `ps aux | grep` + `kill`, each with its own escaping trap and each
    /// able to match the agent's own command line. Here the pid is a number, the
    /// filter is a plain substring, and the mutating actions refuse the processes
    /// that would take the machine down with them.
    func processTool(_ args: [String: Any]) async -> ToolResult {
        let action = (args["action"] as? String)?.lowercased() ?? ""

        if action == "ps" { return Self.processList(args) }
        if action == "info" { return Self.processInfo(args) }
        if action == "signal" { return Self.processSignal(args, tree: false) }
        if action == "kill_tree" { return Self.processSignal(args, tree: true) }

        guard let processes else { return .fail("Фоновые процессы недоступны.") }

        switch action {
        case "run":
            guard let command = args["command"] as? String, !command.isEmpty else {
                return .fail("command обязателен для action=run")
            }
            let cwd = resolve(args["cwd"] as? String ?? ".")
            do {
                let started = try await processes.run(command: command, cwd: cwd)
                return .ok("Запущено: id=\(started.id) pid=\(started.pid)\n"
                    + "process logs id=\(started.id) — вывод; process wait id=\(started.id) — дождаться.")
            } catch {
                return .fail(error.localizedDescription)
            }

        case "list":
            let list = await processes.list()
            guard !list.isEmpty else { return .ok("Фоновых процессов нет.") }
            return .ok(list.map { info in
                let state = info.exitCode.map { "exit \($0)" } ?? "running"
                return "\(info.id) pid=\(info.pid) \(state) \(info.command.prefix(100))"
            }.joined(separator: "\n"))

        case "logs":
            guard let id = args["id"] as? String else { return .fail("id обязателен") }
            do {
                return .ok(try await processes.logs(
                    id: id,
                    lines: Self.int(args, "lines") ?? 50,
                    filter: args["filter"] as? String
                ))
            } catch { return .fail(error.localizedDescription) }

        case "stop":
            guard let id = args["id"] as? String else { return .fail("id обязателен") }
            do {
                try await processes.stop(id: id)
                return .ok("Остановлен \(id).")
            } catch { return .fail(error.localizedDescription) }

        case "wait":
            guard let id = args["id"] as? String else { return .fail("id обязателен") }
            let timeout = Double(min(max(Self.int(args, "timeout_ms") ?? 30_000, 1_000), 600_000)) / 1_000
            do {
                return .ok(try await processes.wait(id: id, timeout: timeout))
            } catch { return .fail(error.localizedDescription) }

        default:
            return .fail("action: run | list | logs | stop | wait | ps | info | signal | kill_tree")
        }
    }

    // MARK: - Read-only inspection

    /// Every process on the machine, filtered by a plain substring.
    ///
    /// `ps` is used rather than `libproc` because a non-root process may not read
    /// `proc_pidinfo` of another user's process: it returns 0 bytes for root-owned
    /// processes, and a listing that silently drops WindowServer is worse than none.
    /// The locale is pinned so the numbers never come back with a comma.
    static func processList(_ args: [String: Any]) -> ToolResult {
        let filter = (args["filter"] as? String)?.lowercased()
        let limit = min(max(Coerce.int(args["limit"]) ?? 20, 1), 200)
        let sort = (args["sort"] as? String)?.lowercased() ?? "memory"

        guard let output = try? runSync(
            "export LC_ALL=C; ps -Ao pid=,ppid=,rss=,pcpu=,etime=,comm=",
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 10
        ) else {
            return .fail("Не удалось прочитать список процессов.")
        }

        struct Row {
            let pid: Int
            let ppid: Int
            let rssKB: Int
            let cpu: Double
            let elapsed: String
            let command: String
        }

        let rows: [Row] = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count == 6,
                  let pid = Int(parts[0]), let ppid = Int(parts[1]),
                  let rss = Int(parts[2]), let cpu = Double(parts[3]) else { return nil }
            let command = String(parts[5])
            if let filter, !command.lowercased().contains(filter) { return nil }
            return Row(pid: pid, ppid: ppid, rssKB: rss, cpu: cpu,
                       elapsed: String(parts[4]), command: command)
        }

        let sorted: [Row]
        switch sort {
        case "cpu": sorted = rows.sorted { $0.cpu > $1.cpu }
        case "pid": sorted = rows.sorted { $0.pid < $1.pid }
        default: sorted = rows.sorted { $0.rssKB > $1.rssKB }
        }

        guard !sorted.isEmpty else {
            return .ok(filter == nil ? "Процессов нет." : "Ничего не найдено по «\(filter!)».")
        }
        let shown = sorted.prefix(limit)
        let header = "\(rows.count) совпадений, показано \(shown.count), сортировка: \(sort)"
        let lines = shown.map { row in
            var line = "pid=\(row.pid) ppid=\(row.ppid) rss=\(row.rssKB / 1024)MB"
            line += " cpu=\(String(format: "%.1f", row.cpu))% up=\(row.elapsed) \(row.command)"
            return line
        }
        return .ok(header + "\n" + lines.joined(separator: "\n"))
    }

    static func processInfo(_ args: [String: Any]) -> ToolResult {
        guard let pid = Self.int(args, "pid") else {
            return .fail("pid обязателен для action=info")
        }
        guard pid > 0 else { return .fail("pid должен быть положительным.") }

        var lines = ["pid=\(pid)"]

        // libproc answers only for processes of the same user; anything else falls
        // through to `ps`, which is allowed to see the whole table.
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(Int32(pid), &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            lines.append("path=\(String(cString: pathBuffer))")
        }

        var bsd = proc_bsdinfo()
        let bsdSize = proc_pidinfo(Int32(pid), PROC_PIDTBSDINFO, 0, &bsd,
                                   Int32(MemoryLayout<proc_bsdinfo>.size))
        if bsdSize > 0 {
            lines.append("ppid=\(bsd.pbi_ppid) uid=\(bsd.pbi_uid) status=\(bsd.pbi_status)")
            lines.append("name=\(Self.fixedString(bsd.pbi_name))")
        }

        var task = proc_taskinfo()
        let taskSize = proc_pidinfo(Int32(pid), PROC_PIDTASKINFO, 0, &task,
                                    Int32(MemoryLayout<proc_taskinfo>.size))
        if taskSize > 0 {
            let rss = Int(task.pti_resident_size) / 1_048_576
            let cpuSeconds = Double(task.pti_total_user + task.pti_total_system) / 1_000_000_000
            lines.append("rss=\(rss)MB threads=\(task.pti_threadnum)"
                + " cpu_time=\(String(format: "%.1f", cpuSeconds))s")
        }

        // `ps` also gives the full command line and the start time, which libproc does not.
        if let ps = try? runSync(
            "export LC_ALL=C; ps -o pid=,ppid=,stat=,lstart=,pcpu=,args= -p \(pid)",
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 5
        ), !ps.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("ps: \(ps.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            lines.append("ps: процесса \(pid) нет (или уже завершился)")
        }

        return .ok(lines.joined(separator: "\n"))
    }

    // MARK: - Mutating

    /// Processes whose death takes the session with it. Refused even with `force`:
    /// there is no task that legitimately needs to kill launchd or WindowServer.
    private static let protectedNames: Set<String> = [
        "launchd", "WindowServer", "loginwindow", "kernel_task", "logind"
    ]

    static func processSignal(_ args: [String: Any], tree: Bool) -> ToolResult {
        guard let pid = Self.int(args, "pid") else {
            return .fail("pid обязателен для action=\(tree ? "kill_tree" : "signal")")
        }
        guard pid > 1 else {
            return .fail("Отказ: pid \(pid) — системный процесс, сигнал не отправлен.")
        }
        if pid == Int(getpid()) {
            return .fail("Отказ: это процесс самого Harness. Остановить себя он не может.")
        }

        let name = (args["signal"] as? String)?.uppercased() ?? "TERM"
        let number = Self.signalNumber(name)
        guard let number else {
            return .fail("Неизвестный сигнал «\(name)». Примеры: TERM, KILL, HUP, INT.")
        }

        let targets: [Int]
        if tree {
            targets = Self.descendants(of: pid)
        } else {
            targets = [pid]
        }

        var sent: [String] = []
        var refused: [String] = []
        var failed: [String] = []

        for target in targets {
            let command = Self.commandLine(of: target)
            let base = URL(fileURLWithPath: command).lastPathComponent
            if protectedNames.contains(base) {
                refused.append("pid=\(target) \(base) — защищён")
                continue
            }
            if kill(Int32(target), Int32(number)) == 0 {
                sent.append("pid=\(target) \(base)")
            } else {
                failed.append("pid=\(target) errno=\(errno) \(String(cString: strerror(errno)))")
            }
        }

        var out: [String] = []
        if !sent.isEmpty { out.append("Отправлен \(name): " + sent.joined(separator: ", ")) }
        if !refused.isEmpty { out.append("Отказано: " + refused.joined(separator: ", ")) }
        if !failed.isEmpty { out.append("Ошибки: " + failed.joined(separator: ", ")) }
        if out.isEmpty { out.append("Нечего останавливать: процессы \(targets) не найдены.") }

        // An escalation hint is only useful when the soft signal found nothing to do.
        if number == SIGTERM, !sent.isEmpty {
            out.append("Если процесс выжил — повтори с signal=KILL (эскалация отдельным вызовом).")
        }
        return refused.isEmpty && failed.isEmpty
            ? .ok(out.joined(separator: "\n"))
            : .fail(out.joined(separator: "\n"))
    }

    /// All descendants of `pid`, deepest last. Built from one `ps` snapshot instead of
    /// walking `pgrep -P` per level: the tree is small and one call is enough.
    static func descendants(of pid: Int) -> [Int] {
        guard let output = try? runSync(
            "export LC_ALL=C; ps -Ao pid=,ppid=",
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 5
        ) else { return [pid] }

        var children: [Int: [Int]] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, let child = Int(parts[0]), let parent = Int(parts[1]) else { continue }
            children[parent, default: []].append(child)
        }

        var result: [Int] = []
        var queue = [pid]
        while let current = queue.popLast() {
            result.append(current)
            queue.append(contentsOf: children[current] ?? [])
        }
        // Deepest last, so a parent is never signalled before its children.
        return result.reversed()
    }

    static func commandLine(of pid: Int) -> String {
        guard let output = try? runSync(
            "export LC_ALL=C; ps -o comm= -p \(pid)",
            cwd: URL(fileURLWithPath: NSTemporaryDirectory()),
            timeout: 5
        ) else { return "?" }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func signalNumber(_ name: String) -> Int32? {
        let name = name.uppercased()
        if let number = Int32(name), number > 0, number < 32 { return number }
        switch name {
        case "TERM", "SIGTERM": return SIGTERM
        case "KILL", "SIGKILL": return SIGKILL
        case "HUP", "SIGHUP": return SIGHUP
        case "INT", "SIGINT": return SIGINT
        case "QUIT", "SIGQUIT": return SIGQUIT
        case "STOP", "SIGSTOP": return SIGSTOP
        case "CONT", "SIGCONT": return SIGCONT
        default: return nil
        }
    }

    private static func fixedString<T>(_ tuple: T) -> String {
        var value = tuple
        return withUnsafeBytes(of: &value) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
