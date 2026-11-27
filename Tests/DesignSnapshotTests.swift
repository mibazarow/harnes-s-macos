import AppKit
import SwiftUI
import XCTest
@testable import Harness

/// Renders the transcript column to PNG for visual review. No pixel comparison: the
/// point is evidence that the view produces a real image in the app's only theme,
/// which is what a reviewer looks at instead of reading colour literals.
@MainActor
final class DesignSnapshotTests: XCTestCase {
    private let assistant = ChatMessage(
        role: .assistant,
        text: """
        Прочитал оба файла. Регистрация событий идёт тремя блоками, и один обработчик \
        объявлен дважды — во втором файле он перекрывает первый.

        ```swift
        use Bitrix\\Main\\EventManager;

        // было: три отдельных блока в разных местах файла
        EventManager::getInstance()->addEventHandler(
            'main',
            'OnBeforeUserAdd',
            'handleUserAdd'
        );
        ```

        Свёл в один блок в конце файла, дубль удалил. Тесты не гонял — живым запуском не проверено.
        """,
        reasoning: "Сначала читаю оба файла, потом сравниваю обработчики.",
        tools: [
            ToolTrace(name: "read_many", summary: "2 файла", isRunning: false, duration: 1.2),
            ToolTrace(name: "edit_file", summary: "init.php · 1 правка", isRunning: false, duration: 0.4),
            ToolTrace(name: "bash", summary: "php -l init.php · синтаксис в порядке", isRunning: false, duration: 0.6),
            ToolTrace(name: "apply_patch", summary: "не применён: контекст не совпал", isError: true, isRunning: false, duration: 0.3),
            ToolTrace(name: "fs_read", summary: "init.php · 214 строк", isRunning: false, duration: 0.5)
        ],
        toolsBeforeText: true
    )

    private var column: some View {
        VStack(alignment: .leading, spacing: Bubble.gap) {
            MessageRow(
                message: ChatMessage(role: .user, text: "Посмотри `init.php` — там регистрация обработчиков размазана. Собери в один блок и убери дубли."),
                fontSize: 13,
                showTimestamp: true
            )
            MessageRow(message: assistant, fontSize: 13, showTimestamp: true)
            MessageRow(
                message: ChatMessage(role: .user, text: "А на проде сколько таких пустых?"),
                fontSize: 13,
                showTimestamp: true
            )
        }
        .frame(width: Layout.chatContainer - Spacing.offGrid32, alignment: .leading)
        .padding(Spacing.offGrid20)
    }

    func testRenderThemeToPNG() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-design")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tokens = ThemeTokens.copper
        let host = NSHostingView(rootView: column
            .environment(LiveResizeState())
            .environment(\.theme, tokens)
            .background(tokens.contentBackground)
            .preferredColorScheme(tokens.scheme)
        )
        // A concrete width first, then the height the column actually needs: fitting
        // size at an unconstrained width reports one long line.
        host.frame = NSRect(origin: .zero, size: NSSize(width: Layout.chatContainer, height: 1200))
        host.layoutSubtreeIfNeeded()
        let needed = host.fittingSize
        host.frame = NSRect(origin: .zero, size: NSSize(width: Layout.chatContainer, height: max(needed.height, 200)))
        host.layoutSubtreeIfNeeded()

        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("bubbles.png")
        try data.write(to: url)
        XCTAssertGreaterThan(data.count, 10_000, "bubbles")
        print("SNAPSHOT \(url.path)")
        window.contentView = nil
    }

    /// A 1600 pt window: the chat column stays at 1100 pt, centred, and the same paper
    /// background continues on both sides — no bands, no rules.
    func testWideWindowKeepsTheColumnAt1100() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-design")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let tokens = ThemeTokens.copper
        let windowWidth: CGFloat = 1_600
        let view = column
            .frame(maxWidth: Layout.chatContainer, maxHeight: .infinity)
            .frame(width: windowWidth, height: 1_100)
            .background(tokens.contentBackground)
            .environment(LiveResizeState())
            .environment(\.theme, tokens)
            .preferredColorScheme(tokens.scheme)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: windowWidth, height: 1_100))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("bubbles-wide.png")
        try data.write(to: url)
        XCTAssertGreaterThan(data.count, 10_000, "bubbles-wide")
        print("SNAPSHOT \(url.path)")

        // 40 pt from the edge must be the chat paper: the cap adds no side band.
        let left = try XCTUnwrap(rep.colorAt(x: 40, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        let paper = try XCTUnwrap(NSColor(tokens.contentBackground).usingColorSpace(.sRGB))
        XCTAssertEqual(left.redComponent, paper.redComponent, accuracy: 0.04)
        XCTAssertEqual(left.greenComponent, paper.greenComponent, accuracy: 0.04)
        XCTAssertEqual(left.blueComponent, paper.blueComponent, accuracy: 0.04)

        window.contentView = nil
    }

    // MARK: - R37: the shots that ship in `design/shots`

    /// Renders the chat column at the two window widths the design folder documents.
    /// `Scripts/demo_screens.sh` needs Accessibility permission for System Events, which
    /// this machine does not grant to the terminal, so the images are produced from the
    /// same views the app runs instead of a live window.
    func testRenderWindowWidths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-design")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for width in [CGFloat(1_240), CGFloat(980)] {
            let view = column
                .frame(maxWidth: Layout.chatContainer, maxHeight: .infinity)
                .frame(width: width, height: 1_100)
                .background(ThemeTokens.copper.contentBackground)
                .environment(LiveResizeState())
                .environment(\.theme, ThemeTokens.copper)
                .preferredColorScheme(.light)

            let host = NSHostingView(rootView: view)
            host.frame = NSRect(origin: .zero, size: NSSize(width: width, height: 1_100))
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let name = width == 1_240 ? "window-1240.png" : "window-980.png"
            let url = directory.appendingPathComponent(name)
            try data.write(to: url)
            XCTAssertGreaterThan(data.count, 10_000, name)
            print("SNAPSHOT \(url.path)")
            window.contentView = nil
        }
    }

    /// The ⌘K palette in the light theme.
    func testRenderPalette() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-design")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let palette = CommandPaletteState()
        palette.open()
        let actions = [
            PaletteAction(id: "settings", title: "Настройки", systemImage: "gearshape") {},
            PaletteAction(id: "find", title: "Найти в чате", systemImage: "magnifyingglass") {},
            PaletteAction(id: "plan", title: "Режим плана", systemImage: "checklist") {},
            PaletteAction(id: "clear", title: "Очистить вид", systemImage: "trash") {},
            PaletteAction(id: "stop", title: "Остановить", systemImage: "stop.circle", isEnabled: false) {}
        ]
        // Over the transcript, as it opens in the app: the scrim is meant to sit on the
        // chat, not on an empty page.
        let view = ZStack {
            column
            CommandPaletteOverlay(palette: palette, actions: actions)
        }
        .frame(width: 1_240, height: 900)
        .environment(LiveResizeState())
        .environment(\.theme, ThemeTokens.copper)
        .preferredColorScheme(.light)

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: NSSize(width: 1_240, height: 900))
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = directory.appendingPathComponent("palette.png")
        try data.write(to: url)
        XCTAssertGreaterThan(data.count, 10_000, "palette")
        print("SNAPSHOT \(url.path)")
        window.contentView = nil
    }

    /// R38: the README screenshots were taken on the dark theme. They are re-rendered
    /// here from the same demo transcripts `Scripts/demo_screens.sh` uses, in the app's
    /// only theme, so the README does not show a look the app no longer has.
    func testRenderReadmeScreenshots() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-design/readme")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scenarios = ["code", "memory", "search", "git", "browser", "markdown"]
        for name in scenarios {
            let messages = try XCTUnwrap(
                DemoTranscript.messages(for: name),
                "нет демо-сценария \(name)"
            )
            let view = VStack(alignment: .leading, spacing: Bubble.gap) {
                ForEach(messages) { message in
                    MessageRow(message: message, fontSize: 13, showTimestamp: true)
                }
            }
            .frame(width: Layout.chatContainer - Spacing.offGrid32, alignment: .leading)
            .padding(Spacing.offGrid20)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(ThemeTokens.copper.contentBackground)
            .environment(LiveResizeState())
            .environment(\.theme, ThemeTokens.copper)
            .preferredColorScheme(.light)

            let host = NSHostingView(rootView: view)
            // Concrete width first, then the height the content needs: an image with a
            // thousand empty points under the answer is not evidence of anything.
            host.frame = NSRect(origin: .zero, size: NSSize(width: 1_240, height: 1_100))
            host.layoutSubtreeIfNeeded()
            let needed = host.fittingSize.height
            host.frame = NSRect(origin: .zero, size: NSSize(width: 1_240, height: max(needed, 240)))
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()

            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
            let url = directory.appendingPathComponent("\(name).png")
            try data.write(to: url)
            XCTAssertGreaterThan(data.count, 10_000, name)
            print("SNAPSHOT \(url.path)")
            window.contentView = nil
        }
    }
}
