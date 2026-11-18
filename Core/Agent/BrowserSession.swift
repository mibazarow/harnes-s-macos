import Foundation

/// R16.6: one persistent browser for the agent.
///
/// The old path launched `chromium.launch({headless:true})` per call and closed it in
/// `finally`: cookies, localStorage and tabs died with the process, so a logged-in site
/// could never be used twice. The browser is now a real app in `~/HARNESS_S_DATA` with a
/// fixed profile and a debug port; this type only makes sure it is running and hands the
/// endpoint to `browser.mjs`.
struct BrowserPaths: Equatable, Sendable {
    let bundle: URL
    let profile: URL
    let log: URL
    let port: Int

    static var standard: BrowserPaths {
        BrowserPaths(
            bundle: AppPaths.dataDirectory.appendingPathComponent(
                "HarnessBrowser.app", isDirectory: true
            ),
            profile: AppPaths.dataDirectory.appendingPathComponent(
                "browser-profile", isDirectory: true
            ),
            log: AppPaths.logsDirectory.appendingPathComponent("browser.log"),
            port: 9222
        )
    }

    /// The path inside the bundle: Google Chrome for Testing keeps this exact name.
    var executable: URL {
        bundle.appendingPathComponent("Contents/MacOS/Google Chrome for Testing")
    }

    var infoPlist: URL {
        bundle.appendingPathComponent("Contents/Info.plist")
    }

    var endpoint: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var versionURL: URL {
        endpoint.appendingPathComponent("json/version")
    }

    /// R16.6: a live port is not a live browser. `/json/list` is what tells a usable
    /// Chrome from a process that holds 9222 but cannot create a tab.
    var listURL: URL {
        endpoint.appendingPathComponent("json/list")
    }

    var launchArguments: [String] {
        [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(profile.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--restore-last-session",
            // A minimised window otherwise throttles background tabs, and `wait`/
            // `network` time out on a browser that is alive but asleep.
            "--disable-backgrounding-occluded-windows"
        ]
    }

    /// The selected tab survives between tool calls here; it is not browser state, so it
    /// lives outside the profile and can be deleted without logging anybody out.
    var stateFile: URL {
        AppPaths.dataDirectory.appendingPathComponent("tools/browser-session.json")
    }

    /// Lock files Chrome leaves behind when it dies without cleaning up. A stale
    /// `SingletonLock` makes the next launch exit immediately on the same profile.
    static let singletonFiles = ["SingletonLock", "SingletonSocket", "SingletonCookie"]

    var singletonURLs: [URL] {
        Self.singletonFiles.map { profile.appendingPathComponent($0) }
    }

    /// `CFBundleShortVersionString` from the bundle, if the plist can be read.
    var bundleVersion: String? {
        guard let data = try? Data(contentsOf: infoPlist),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else { return nil }
        return plist["CFBundleShortVersionString"] as? String
    }
}

enum BrowserSessionState: Equatable, Sendable {
    case ready(URL)
    /// The browser is not running at all. This is a normal state before the first
    /// launch, not an error, so callers do not show it as one.
    case notRunning(BrowserPaths)
    case failed(String)
}

/// Lazy start, one instance. An actor because two tool calls in one turn must not launch
/// the browser twice.
actor BrowserSession {
    /// Everything the actor touches is injectable: the tests exercise the cases
    /// (already ours, foreign port, broken profile, missing bundle, launch timeout)
    /// without a browser.
    struct Hooks: Sendable {
        var portResponds: @Sendable (URL) async -> Bool
        var ownerIsOurs: @Sendable (BrowserPaths) -> Bool
        /// R16.6: at least one `type == "page"` target with a debugger URL.
        var targetsAlive: @Sendable (URL) async -> Bool
        var launch: @Sendable (BrowserPaths) throws -> Void
        /// Stops only our own browser: `pgrep -f HarnessBrowser`, SIGTERM, then SIGKILL.
        var killOurProcess: @Sendable (BrowserPaths) async -> Void
        /// Removes `Singleton*` from the profile and returns the names it removed.
        var removeProfileLocks: @Sendable (BrowserPaths) -> [String]
        var pause: @Sendable (TimeInterval) async -> Void

        static var live: Hooks {
            Hooks(
                portResponds: { url in
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 2
                    guard let (_, response) = try? await URLSession.shared.data(for: request),
                          let http = response as? HTTPURLResponse else { return false }
                    return http.statusCode == 200
                },
                ownerIsOurs: { paths in
                    // `pgrep -fl` prints "pid command"; our own bundle path in the argv is
                    // the difference between "our browser" and "somebody else's Chrome".
                    guard let output = try? ToolRegistry.runSync(
                        "pgrep -fl HarnessBrowser", cwd: paths.bundle.deletingLastPathComponent(),
                        timeout: 5
                    ) else { return false }
                    return output.contains(paths.bundle.path)
                        || output.contains("HarnessBrowser.app/Contents/MacOS")
                },
                targetsAlive: { url in
                    await BrowserSession.hasLivePageTarget(at: url)
                },
                launch: { paths in
                    try AppPaths.ensureDirectory(paths.profile)
                    try AppPaths.ensureDirectory(paths.log.deletingLastPathComponent())
                    FileManager.default.createFile(
                        atPath: paths.log.path, contents: nil,
                        attributes: [.posixPermissions: 0o600]
                    )
                    let command = ([paths.executable.path] + paths.launchArguments)
                        .map(ToolRegistry.shellQuote)
                        .joined(separator: " ")
                    _ = try ShellSpawn.spawn(
                        command: command,
                        cwd: paths.bundle.deletingLastPathComponent(),
                        stdoutPath: paths.log.path,
                        stderrPath: paths.log.path,
                        append: true
                    )
                },
                killOurProcess: { paths in
                    await BrowserSession.terminateOurProcess(paths)
                },
                removeProfileLocks: { paths in
                    var removed: [String] = []
                    for (name, url) in zip(BrowserPaths.singletonFiles, paths.singletonURLs) {
                        guard FileManager.default.fileExists(atPath: url.path) else { continue }
                        if (try? FileManager.default.removeItem(at: url)) != nil {
                            removed.append(name)
                        }
                    }
                    return removed
                },
                pause: { seconds in
                    try? await Task.sleep(for: .seconds(seconds))
                }
            )
        }
    }

    static let shared = BrowserSession()

    private let paths: BrowserPaths
    private let hooks: Hooks

    init(paths: BrowserPaths = .standard, hooks: Hooks = .live) {
        self.paths = paths
        self.hooks = hooks
    }

    nonisolated var stateFile: URL { paths.stateFile }
    nonisolated var port: Int { paths.port }

    /// What the port and the targets say right now, without launching anything.
    func currentState() async -> BrowserSessionState {
        switch await probe() {
        case .ready:
            return .ready(paths.endpoint)
        case .foreign:
            return .failed(Self.foreignPortMessage(port: paths.port))
        case .broken:
            return .failed(Self.brokenProfileMessage(port: paths.port))
        case .absent:
            return .notRunning(paths)
        }
    }

    /// Ready with the CDP endpoint, or a refusal that names the reason. Never kills a
    /// process it did not start.
    func ensureRunning(deadline: TimeInterval = 15) async -> BrowserSessionState {
        switch await probe() {
        case .ready:
            return .ready(paths.endpoint)
        case .foreign:
            return .failed(Self.foreignPortMessage(port: paths.port))
        case .broken:
            return await healAndLaunch(deadline: deadline)
        case .absent:
            break
        }

        guard FileManager.default.fileExists(atPath: paths.executable.path) else {
            return .failed(Self.missingExecutableMessage(paths))
        }

        // A second launch on the same profile makes Chrome exit immediately; the poll
        // below then reports the log path instead of pretending it started.
        do {
            try hooks.launch(paths)
        } catch {
            return .failed("Не удалось запустить браузер: \(error.localizedDescription). "
                + "Лог: \(paths.log.path)")
        }

        if await waitUntilAlive(deadline: deadline) {
            return .ready(paths.endpoint)
        }
        return .failed(
            "Браузер не открыл порт \(paths.port) за \(Int(deadline)) с. "
            + "Лог: \(paths.log.path)"
        )
    }

    // MARK: - Probing

    private enum Probe {
        case ready
        case foreign
        case broken
        case absent
    }

    /// R16.6: a port that answers is not enough. Chrome can keep the socket open after
    /// its renderer is gone and then never create a page, so the browser counts as alive
    /// only when the port, the process and at least one page target all agree.
    private func probe() async -> Probe {
        guard await hooks.portResponds(paths.versionURL) else { return .absent }
        guard hooks.ownerIsOurs(paths) else { return .foreign }
        guard await hooks.targetsAlive(paths.listURL) else { return .broken }
        return .ready
    }

    /// Broken profile: our process holds the port but serves no pages. Kill only our own
    /// process, clear the singleton files, start again. A foreign process is never
    /// touched — that case returned before this function is reached.
    private func healAndLaunch(deadline: TimeInterval) async -> BrowserSessionState {
        await hooks.killOurProcess(paths)
        let removed = hooks.removeProfileLocks(paths)
        let healed = removed.isEmpty
            ? "перезапустил браузер (файлов Singleton* не было)"
            : "перезапустил браузер и удалил \(removed.joined(separator: ", "))"

        guard FileManager.default.fileExists(atPath: paths.executable.path) else {
            return .failed("\(healed), но бинарь пропал: \(Self.missingExecutableMessage(paths))")
        }

        do {
            try hooks.launch(paths)
        } catch {
            return .failed(
                "Браузер держал порт \(paths.port), но не открывал вкладок; \(healed). "
                + "Повторный запуск не удался: \(error.localizedDescription). "
                + "Лог: \(paths.log.path)"
            )
        }

        if await waitUntilAlive(deadline: deadline) {
            return .ready(paths.endpoint)
        }
        return .failed(
            "Браузер держал порт \(paths.port), но не открывал вкладок; \(healed), "
            + "вкладок всё равно нет за \(Int(deadline)) с. Лог: \(paths.log.path)"
        )
    }

    private func waitUntilAlive(deadline: TimeInterval) async -> Bool {
        let step: TimeInterval = 0.25
        var waited: TimeInterval = 0
        while waited < deadline {
            await hooks.pause(step)
            waited += step
            guard await hooks.portResponds(paths.versionURL) else { continue }
            guard hooks.ownerIsOurs(paths) else { continue }
            if await hooks.targetsAlive(paths.listURL) { return true }
        }
        return false
    }

    // MARK: - Messages and helpers

    private static func foreignPortMessage(port: Int) -> String {
        "Порт \(port) занят другим Chrome. Не убиваю чужой процесс: "
            + "закрой его сам или задай другой порт."
    }

    private static func brokenProfileMessage(port: Int) -> String {
        "Порт \(port) отвечает, но у браузера нет ни одной вкладки. "
            + "Состояние профиля битое: перезапусти браузер."
    }

    private static func missingExecutableMessage(_ paths: BrowserPaths) -> String {
        var message = "Браузер не найден: \(paths.bundle.path). "
        if let version = paths.bundleVersion {
            message += "Info.plist сообщает версию \(version), но бинаря нет: "
                + "\(paths.executable.path). "
        } else {
            message += "Бинаря нет: \(paths.executable.path); "
                + "Info.plist не читается или в нём нет CFBundleShortVersionString. "
        }
        return message + "Положи туда Google Chrome for Testing "
            + "(Contents/MacOS/Google Chrome for Testing). Сам ничего не скачиваю."
    }

    /// `GET /json/list` is alive when at least one page target has a debugger URL.
    static func hasLivePageTarget(at url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        return hasLivePageTarget(in: data)
    }

    /// Parsed separately so the shape of `/json/list` is testable without a browser.
    static func hasLivePageTarget(in data: Data) -> Bool {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        return list.contains { entry in
            guard (entry["type"] as? String) == "page" else { return false }
            let socket = entry["webSocketDebuggerUrl"] as? String ?? ""
            return !socket.isEmpty
        }
    }

    /// Stops our own browser only: the caller already established ownership. SIGTERM
    /// first, five seconds to exit, then SIGKILL; a foreign Chrome never matches the
    /// bundle path in its argv.
    static func terminateOurProcess(_ paths: BrowserPaths) async {
        guard let output = try? ToolRegistry.runSync(
            "pgrep -fl HarnessBrowser", cwd: paths.bundle.deletingLastPathComponent(),
            timeout: 5
        ) else { return }

        let pids: [pid_t] = output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2 else { return nil }
            let command = String(parts[1])
            guard command.contains(paths.bundle.path)
                || command.contains("HarnessBrowser.app/Contents/MacOS") else { return nil }
            return pid_t(parts[0])
        }
        guard !pids.isEmpty else { return }

        for pid in pids { kill(pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if pids.allSatisfy({ kill($0, 0) != 0 }) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
        for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }
}
