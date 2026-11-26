import SwiftUI
import XCTest
@testable import Harness

/// Smoke tests for the HIG layout: the new views must lay out in every theme and must
/// not depend on the old bubble or on a palette passed down by hand.
@MainActor
final class DesignLayoutTests: XCTestCase {
    private func host<Content: View>(_ view: Content, width: CGFloat = 900) -> NSHostingView<Content> {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: width, height: 600)
        return host
    }

    private func environments<Content: View>(_ view: Content, theme: ThemeTokens) -> some View {
        view
            .environment(LiveResizeState())
            .environment(\.theme, theme)
    }

    func testMessageRowLaysOutInEveryTheme() throws {
        let assistant = ChatMessage(
            role: .assistant,
            text: "Готово.\n\n```swift\nlet x = 1\n```",
            reasoning: "сначала читаю",
            tools: [ToolTrace(name: "bash", summary: "exit 0", isRunning: false)]
        )
        for theme in [ThemeTokens.system, .systemDark, .systemLight, .copper] {
            let host = host(environments(
                MessageRow(message: assistant, fontSize: 13, showTimestamp: true),
                theme: theme
            ))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.fittingSize.height, 80, theme.id)
            XCTAssertGreaterThan(host.fittingSize.width, 0, theme.id)
        }
    }

    func testRowLaysOutAtNarrowWidthWithoutCrashing() throws {
        let assistant = ChatMessage(role: .assistant, text: String(repeating: "слово ", count: 400))
        let host = host(environments(
            MessageRow(message: assistant, fontSize: 13, showTimestamp: false),
            theme: .system
        ), width: 560)
        host.layoutSubtreeIfNeeded()
        // `fittingSize` reports the ideal size at an unconstrained width, so the useful
        // assertion here is that layout completes with real content in a narrow host.
        XCTAssertGreaterThan(host.fittingSize.height, 0)
    }

    func testProseColumnIsNarrowerThanTheContainer() {
        // Step 6: 1100 pt container, 760 pt prose, code and tables on the full width.
        XCTAssertLessThan(Layout.textColumn, Layout.chatContainer)
        XCTAssertLessThanOrEqual(Layout.textColumn, 760)
        XCTAssertLessThanOrEqual(Layout.chatContainer, 1_100)
    }

    func testCodeBlockLaysOutWithAVeryLongLine() throws {
        let longLine = "let value = \"" + String(repeating: "x", count: 400) + "\""
        let assistant = ChatMessage(role: .assistant, text: "```swift\n\(longLine)\n```")
        let host = host(environments(
            MessageRow(message: assistant, fontSize: 13, showTimestamp: false),
            theme: .copper
        ), width: 800)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 40, "блок кода отрисован")
    }

    func testThemesAreDistinctAndCarryRoles() {
        let system = ThemeTokens.system
        XCTAssertNil(system.scheme, "системная тема следует за системой")
        XCTAssertEqual(ThemeTokens.systemDark.scheme, .dark)
        XCTAssertEqual(ThemeTokens.systemLight.scheme, .light)
        XCTAssertNil(ThemeTokens.copper.scheme)
        XCTAssertNotEqual(system.accent, ThemeTokens.copper.accent)
    }

    func testHeaderBarIsGone() throws {
        // The native toolbar replaced it; the type must not exist any more.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("App/RootView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("struct HeaderBar"), "HeaderBar должен быть удалён")
        XCTAssertTrue(source.contains(".toolbar"), "содержимое должно переехать в тулбар")
    }
}
