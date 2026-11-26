import SwiftUI
import XCTest
@testable import Harness

/// Smoke tests for the HIG layout: the views must lay out in the app's only theme and
/// must not depend on the old bubble or on a palette passed down by hand.
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

    func testMessageRowLaysOutInTheTheme() throws {
        let assistant = ChatMessage(
            role: .assistant,
            text: "Готово.\n\n```swift\nlet x = 1\n```",
            reasoning: "сначала читаю",
            tools: [ToolTrace(name: "bash", summary: "exit 0", isRunning: false)]
        )
        let theme = ThemeTokens.copper
        let host = host(environments(
            MessageRow(message: assistant, fontSize: 13, showTimestamp: true),
            theme: theme
        ))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 80, theme.id)
        XCTAssertGreaterThan(host.fittingSize.width, 0, theme.id)
    }

    func testRowLaysOutAtNarrowWidthWithoutCrashing() throws {
        let assistant = ChatMessage(role: .assistant, text: String(repeating: "слово ", count: 400))
        let host = host(environments(
            MessageRow(message: assistant, fontSize: 13, showTimestamp: false),
            theme: .copper
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

    func testThereIsOneThemeAndItIsDark() {
        XCTAssertEqual(ThemeTokens.copper.id, "copper")
        XCTAssertEqual(ThemeTokens.copper.scheme, .dark)
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

/// The user's message must be visually distinct from the answer in every theme, and the
/// answer must stay plain prose.
@MainActor
final class UserBubbleTests: XCTestCase {
    private func luminance(_ color: NSColor) throws -> Double {
        let rgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
            $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }

    private func contrast(_ a: NSColor, _ b: NSColor) throws -> Double {
        let x = try luminance(a)
        let y = try luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    func testCopperBubbleDiffersFromTheBackground() throws {
        let palette = Palette()
        let bubble = try XCTUnwrap(NSColor(palette.userBackground).usingColorSpace(.sRGB))
        let background = try XCTUnwrap(NSColor(palette.background).usingColorSpace(.sRGB))
        XCTAssertGreaterThan(
            abs(try luminance(bubble) - luminance(background)), 0.005,
            "медный пузырь должен быть виден"
        )
    }

    func testUserTextStaysReadableOnItsBubble() throws {
        let palette = Palette()
        let text = try XCTUnwrap(NSColor(palette.text).usingColorSpace(.sRGB))
        let bubble = try XCTUnwrap(NSColor(palette.userBackground).usingColorSpace(.sRGB))
        XCTAssertGreaterThanOrEqual(try contrast(text, bubble), 4.5, "текст на пузыре Copper должен читаться")
    }

    func testCopperKeepsTheOldUserShade() {
        XCTAssertEqual(Palette().userBackground, Color(hex: 0x1F1B16))
    }
}
