import XCTest
@testable import Harness

/// R16.6: the session decides six things without ever touching a real browser — ours,
/// foreign port, broken profile, missing bundle, missing binary in an existing bundle,
/// launch that never opens the port — and the script must connect instead of launch and
/// must never close the live browser.
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

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func bump() { lock.lock(); value += 1; lock.unlock() }
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func session(
        paths: BrowserPaths,
        portUp: @escaping @Sendable () -> Bool,
        ours: Bool = true,
        targetsAlive: @escaping @Sendable () -> Bool = { true },
        launch: @escaping @Sendable () -> Void = {},
        kill: @escaping @Sendable () -> Void = {},
        removeLocks: @escaping @Sendable () -> [String] = { [] }
    ) -> BrowserSession {
        BrowserSession(
            paths: paths,
            hooks: BrowserSession.Hooks(
                portResponds: { _ in portUp() },
                ownerIsOurs: { _ in ours },
                targetsAlive: { _ in targetsAlive() },
                launch: { _ in launch() },
                killOurProcess: { _ in kill() },
                removeProfileLocks: { _ in removeLocks() },
                pause: { _ in }
            )
        )
    }

    func testReadyWhenOurBrowserAnswersWithAPage() async throws {
        let paths = try paths()
        let session = session(paths: paths, portUp: { true })

        let state = await session.ensureRunning()
        XCTAssertEqual(state, .ready(paths.endpoint))
        XCTAssertEqual(paths.endpoint.absoluteString, "http://127.0.0.1:9222")
    }

    func testOpenPortWithoutTargetsIsNotReady() async throws {
        let paths = try paths()
        let session = session(paths: paths, portUp: { true }, targetsAlive: { false })

        let state = await session.ensureRunning(deadline: 0.5)
        guard case .failed(let reason) = state else {
            return XCTFail("порт без вкладок не должен считаться готовым: \(state)")
        }
        XCTAssertTrue(reason.contains("не открывал вкладок"), reason)
    }

    func testBrokenProfileIsHealedByName() async throws {
        let paths = try paths()
        let killed = Flag(false)
        let launched = Counter()
        let session = session(
            paths: paths,
            portUp: { true },
            targetsAlive: { false },
            launch: { launched.bump() },
            kill: { killed.current = true },
            removeLocks: { ["SingletonLock", "SingletonCookie"] }
        )

        let state = await session.ensureRunning(deadline: 0.5)
        guard case .failed(let reason) = state else {
            return XCTFail("битый профиль должен лечиться и всё равно отказать")
        }
        XCTAssertTrue(killed.current, "свой процесс должен быть погашен")
        XCTAssertEqual(launched.current, 1, "браузер должен быть запущен заново")
        XCTAssertTrue(reason.contains("перезапустил"), reason)
        XCTAssertTrue(reason.contains("SingletonLock"), reason)
        XCTAssertTrue(reason.contains("SingletonCookie"), reason)
    }

    func testHealedProfileBecomesReady() async throws {
        let paths = try paths()
        let relaunched = Flag(false)
        let session = BrowserSession(
            paths: paths,
            hooks: BrowserSession.Hooks(
                portResponds: { _ in true },
                ownerIsOurs: { _ in true },
                // Broken until the relaunch, alive afterwards.
                targetsAlive: { _ in relaunched.current },
                launch: { _ in relaunched.current = true },
                killOurProcess: { _ in },
                removeProfileLocks: { _ in ["SingletonLock"] },
                pause: { _ in }
            )
        )

        let state = await session.ensureRunning(deadline: 1)
        XCTAssertEqual(state, .ready(paths.endpoint))
    }

    func testAbsentBrowserIsNotRunningNotAnError() async throws {
        let paths = try paths()
        let session = session(paths: paths, portUp: { false })

        let state = await session.currentState()
        XCTAssertEqual(state, .notRunning(paths))
    }

    func testForeignPortIsRefusedWithoutKillingIt() async throws {
        let paths = try paths()
        let killed = Flag(false)
        let session = session(
            paths: paths, portUp: { true }, ours: false, kill: { killed.current = true }
        )

        let state = await session.ensureRunning()
        guard case .failed(let reason) = state else {
            return XCTFail("чужой порт должен быть отказом")
        }
        XCTAssertTrue(reason.contains("занят другим Chrome"), reason)
        XCTAssertTrue(reason.contains("Не убиваю"), reason)
        XCTAssertFalse(killed.current, "чужой процесс трогать нельзя")
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

    func testEmptyBundleNamesTheExactBinaryAndVersion() async throws {
        // A bundle exists with an Info.plist but no Contents/MacOS: the old check only
        // asked whether the bundle folder was there and then failed at launch time.
        let bundle = root.appendingPathComponent("HarnessBrowser.app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleShortVersionString": "131.0.6778.85",
            "CFBundleIdentifier": "com.google.Chrome.forTesting"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let paths = BrowserPaths(
            bundle: bundle,
            profile: root.appendingPathComponent("browser-profile", isDirectory: true),
            log: root.appendingPathComponent("browser.log"),
            port: 9222
        )
        let session = session(paths: paths, portUp: { false })

        let state = await session.ensureRunning()
        guard case .failed(let reason) = state else {
            return XCTFail("пустой бандл должен быть отказом")
        }
        XCTAssertTrue(reason.contains(paths.executable.path), reason)
        XCTAssertTrue(reason.contains("131.0.6778.85"), reason)
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
                targetsAlive: { _ in true },
                launch: { _ in started.current = true },
                killOurProcess: { _ in },
                removeProfileLocks: { _ in [] },
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
        XCTAssertTrue(
            arguments.contains("--disable-backgrounding-occluded-windows"),
            "свёрнутое окно иначе тормозит фоновые вкладки и ломает wait/network"
        )
    }

    func testTargetListNeedsAPageWithADebuggerURL() {
        let page = Data(#"[{"type":"page","webSocketDebuggerUrl":"ws://127.0.0.1:9222/devtools/page/1"}]"#.utf8)
        let empty = Data("[]".utf8)
        let worker = Data(#"[{"type":"service_worker","webSocketDebuggerUrl":"ws://x"}]"#.utf8)
        let noSocket = Data(#"[{"type":"page","webSocketDebuggerUrl":""}]"#.utf8)

        XCTAssertTrue(BrowserSession.hasLivePageTarget(in: page))
        XCTAssertFalse(BrowserSession.hasLivePageTarget(in: empty))
        XCTAssertFalse(BrowserSession.hasLivePageTarget(in: worker))
        XCTAssertFalse(BrowserSession.hasLivePageTarget(in: noSocket))
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
