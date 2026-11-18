import XCTest
@testable import Harness

/// R16.6: the session decides four things without ever touching a real browser — ours,
/// foreign port, missing bundle, launch that never opens the port — and the script must
/// connect instead of launch and must never close the live browser.
final class BrowserSessionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func paths(withExecutable: Bool = true) throws -> BrowserPaths {
        let bundle = root.appendingPathComponent("HarnessBrowser.app", isDirectory: true)
        let executable = bundle.appendingPathComponent("Contents/MacOS/Google Chrome for Testing")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if withExecutable {
            try Data().write(to: executable)
        }
        return BrowserPaths(
            bundle: bundle,
            profile: root.appendingPathComponent("browser-profile", isDirectory: true),
            log: root.appendingPathComponent("browser.log"),
            port: 9222
        )
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var current: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    private func session(
        paths: BrowserPaths,
        portUp: @escaping @Sendable () -> Bool,
        ours: Bool = true,
        launch: @escaping @Sendable () -> Void = {}
    ) -> BrowserSession {
        BrowserSession(
            paths: paths,
            hooks: BrowserSession.Hooks(
                portResponds: { _ in portUp() },
                ownerIsOurs: { _ in ours },
                launch: { _ in launch() },
                pause: { _ in }
            )
        )
    }

    func testReadyWhenOurBrowserAnswers() async throws {
        let paths = try paths()
        let session = session(paths: paths, portUp: { true })

        let state = await session.ensureRunning()
        XCTAssertEqual(state, .ready(paths.endpoint))
        XCTAssertEqual(paths.endpoint.absoluteString, "http://127.0.0.1:9222")
    }

    func testForeignPortIsRefusedWithoutKillingIt() async throws {
        let paths = try paths()
        let session = session(paths: paths, portUp: { true }, ours: false)

        let state = await session.ensureRunning()
        guard case .failed(let reason) = state else {
            return XCTFail("чужой порт должен быть отказом")
        }
        XCTAssertTrue(reason.contains("занят другим Chrome"), reason)
        XCTAssertTrue(reason.contains("Не убиваю"), reason)
    }

    func testMissingBundleNamesThePath() async throws {
        let paths = try paths(withExecutable: false)
        let session = session(paths: paths, portUp: { false })

        let state = await session.ensureRunning()
        guard case .failed(let reason) = state else {
            return XCTFail("без бандла должен быть отказ")
        }
        XCTAssertTrue(reason.contains(paths.bundle.path), reason)
        XCTAssertTrue(reason.contains("не найден"), reason)
    }

    func testLaunchThatNeverOpensThePortIsAFailure() async throws {
        let paths = try paths()
        let launched = Flag(false)
        let session = session(
            paths: paths, portUp: { false },
            launch: { launched.current = true }
        )

        let state = await session.ensureRunning(deadline: 0.5)
        guard case .failed(let reason) = state else {
            return XCTFail("молчаливый запуск должен быть отказом")
        }
        XCTAssertTrue(launched.current, "браузер должен был запускаться")
        XCTAssertTrue(reason.contains("не открыл порт"), reason)
        XCTAssertTrue(reason.contains(paths.log.path), reason)
    }

    func testLaunchThenReady() async throws {
        let paths = try paths()
        let started = Flag(false)
        let session = BrowserSession(
            paths: paths,
            hooks: BrowserSession.Hooks(
                portResponds: { _ in started.current },
                ownerIsOurs: { _ in true },
                launch: { _ in started.current = true },
                pause: { _ in }
            )
        )

        let state = await session.ensureRunning(deadline: 2)
        XCTAssertEqual(state, .ready(paths.endpoint))
    }

    func testLaunchArgumentsUseTheFixedProfileAndPort() throws {
        let paths = try paths()
        let arguments = paths.launchArguments

        XCTAssertTrue(arguments.contains("--remote-debugging-port=9222"))
        XCTAssertTrue(arguments.contains("--user-data-dir=\(paths.profile.path)"))
        XCTAssertTrue(arguments.contains("--restore-last-session"))
        XCTAssertTrue(arguments.contains("--no-first-run"))
    }

    func testScriptConnectsAndNeverClosesTheBrowser() {
        let script = ToolRegistry.browserScript

        XCTAssertTrue(script.contains("connectOverCDP"), "сессия должна подключаться, а не запускать")
        XCTAssertFalse(script.contains("chromium.launch"), "одноразовый запуск запрещён")
        XCTAssertFalse(script.contains("browser.close"), "закрывать живой браузер нельзя")
        for action in [
            "list", "tabs", "switch", "back", "forward", "reload",
            "wait", "eval", "network", "state"
        ] {
            XCTAssertTrue(script.contains("'\(action)'"), "нет действия \(action)")
        }
    }

    func testStateFileLivesOutsideTheProfile() throws {
        let paths = try paths()
        XCTAssertFalse(paths.stateFile.path.hasPrefix(paths.profile.path + "/"))
        XCTAssertTrue(paths.stateFile.path.hasSuffix("browser-session.json"))
    }
}
