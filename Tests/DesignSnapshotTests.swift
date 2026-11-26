import AppKit
import SwiftUI
import XCTest
@testable import Harness

/// Renders the transcript column to PNG for visual review. No pixel comparison: the
/// point is evidence that the views produce a real image in each theme, which is what a
/// reviewer looks at instead of reading colour literals.
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
            ToolTrace(name: "read_many", summary: "2 файла", isRunning: false),
            ToolTrace(name: "edit_file", summary: "init.php · 1 правка", isRunning: false)
        ]
    )

    private var column: some View {
        VStack(alignment: .leading, spacing: Spacing.offGrid10) {
            MessageRow(
                message: ChatMessage(role: .user, text: "Посмотри `init.php` — там регистрация обработчиков размазана. Собери в один блок и убери дубли."),
                fontSize: 13,
                showTimestamp: true
            )
            MessageRow(message: assistant, fontSize: 13, showTimestamp: true)
        }
        .frame(width: Layout.chatContainer - Spacing.offGrid32, alignment: .leading)
        .padding(Spacing.offGrid20)
    }

    func testRenderThemesToPNG() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-design")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for (name, tokens) in [
            ("system-light", ThemeTokens.systemLight),
            ("system-dark", ThemeTokens.systemDark),
            ("copper", ThemeTokens.copper)
        ] {
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
            window.appearance = NSAppearance(named: tokens.scheme == .dark ? .darkAqua : .aqua)
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
