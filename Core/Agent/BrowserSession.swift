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

    var endpoint: URL {
        URL(string: "http://127.0.0.1:\(port)")!
    }

    var versionURL: URL {
        endpoint.appendingPathComponent("json/version")
    }

    var launchArguments: [String] {
        [
            "--remote-debugging-port=\(port)",
            "--user-data-dir=\(profile.path)",
            "--no-first-run",
            "--no-default-browser-check",
            "--restore-last-session"
        ]
    }

    /// The selected tab survives between tool calls here; it is not browser state, so it
    /// lives outside the profile and can be deleted without logging anybody out.
    var stateFile: URL {
        AppPaths.dataDirectory.appendingPathComponent("tools/browser-session.json")
    }
}

enum BrowserSessionState: Equatable, Sendable {
    case ready(URL)
    case failed(String)
}

/// Lazy start, one instance. An actor because two tool calls in one turn must not launch
/// the browser twice.
actor BrowserSession {
    /// Everything the actor touches is injectable: the tests exercise the four cases
    /// (already ours, foreign port, missing bundle, launch timeout) without a browser.
    struct Hooks: Sendable {
        var portResponds: @Sendable (URL) async -> Bool
        var ownerIsOurs: @Sendable (BrowserPaths) -> Bool
        var launch: @Sendable (BrowserPaths) throws -> Void
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
                pause: { seconds in
                    try? await Task.sleep(for: .seconds(seconds))
                }
            )
        }
    }

    static let shared = BrowserSession()

    private let paths: BrowserPaths
    private let hooks: Hooks
    private var launching = false

    init(paths: BrowserPaths = .standard, hooks: Hooks = .live) {
        self.paths = paths
        self.hooks = hooks
    }

    nonisolated var stateFile: URL { paths.stateFile }
    nonisolated var port: Int { paths.port }

    /// Ready with the CDP endpoint, or a refusal that names the reason. Never kills a
    /// process it did not start.
    func ensureRunning(deadline: TimeInterval = 15) async -> BrowserSessionState {
        if await hooks.portResponds(paths.versionURL) {
            guard hooks.ownerIsOurs(paths) else {
                return .failed(
                    "Порт \(paths.port) занят другим Chrome. Не убиваю чужой процесс: "
                    + "закрой его сам или задай другой порт."
                )
            }
            return .ready(paths.endpoint)
        }

        guard FileManager.default.fileExists(atPath: paths.executable.path) else {
            return .failed(
                "Браузер не найден: \(paths.bundle.path). Положи туда "
                + "Google Chrome for Testing (Contents/MacOS/Google Chrome for Testing). "
                + "Сам ничего не скачиваю."
            )
        }

        // A second launch on the same profile makes Chrome exit immediately; the poll
        // below then reports the log path instead of pretending it started.
        do {
            try hooks.launch(paths)
        } catch {
            return .failed("Не удалось запустить браузер: \(error.localizedDescription). "
                + "Лог: \(paths.log.path)")
        }

        let step: TimeInterval = 0.25
        var waited: TimeInterval = 0
        while waited < deadline {
            await hooks.pause(step)
            waited += step
            if await hooks.portResponds(paths.versionURL) {
                return .ready(paths.endpoint)
            }
        }
        return .failed(
            "Браузер не открыл порт \(paths.port) за \(Int(deadline)) с. "
            + "Лог: \(paths.log.path)"
        )
    }
}
