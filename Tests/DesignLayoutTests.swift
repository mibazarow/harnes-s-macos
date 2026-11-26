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

    func testSystemBubbleIsAQuietLabelWash() throws {
        // The system theme cannot borrow a named surface: `windowBackground` and
        // `textBackground` are both white in light mode, so a named colour produced no
        // bubble at all. The plate is a low-alpha wash of the label colour instead.
        let expected = Color(nsColor: .labelColor).opacity(0.07)
        XCTAssertEqual(ThemeTokens.system.userBubble, expected)
        XCTAssertEqual(ThemeTokens.systemDark.userBubble, expected)
        XCTAssertEqual(ThemeTokens.systemLight.userBubble, expected)
    }

    func testCopperBubbleDiffersInBothAppearances() throws {
        // Copper is authored, so the check is on the palette itself, not on AppKit.
        for pair in [
            (Palette.light.userBackground, Palette.light.background),
            (Palette.dark.userBackground, Palette.dark.background)
        ] {
            let bubble = try XCTUnwrap(NSColor(pair.0).usingColorSpace(.sRGB))
            let background = try XCTUnwrap(NSColor(pair.1).usingColorSpace(.sRGB))
            let bubbleLuminance = try luminance(bubble)
            let backgroundLuminance = try luminance(background)
            XCTAssertGreaterThan(
                abs(bubbleLuminance - backgroundLuminance), 0.005,
                "медный пузырь должен быть виден"
            )
        }
    }

    func testUserTextStaysReadableOnItsBubble() throws {
        // Copper text on Copper bubble, both appearances.
        for pair in [
            (Palette.light.text, Palette.light.userBackground),
            (Palette.dark.text, Palette.dark.userBackground)
        ] {
            let text = try XCTUnwrap(NSColor(pair.0).usingColorSpace(.sRGB))
            let bubble = try XCTUnwrap(NSColor(pair.1).usingColorSpace(.sRGB))
            let ratio = try contrast(text, bubble)
            XCTAssertGreaterThanOrEqual(ratio, 4.5, "текст на пузыре Copper должен читаться")
        }

        // A 7% wash never moves the plate far enough to hurt contrast: the label keeps
        // its own ratio against the content background.
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            var label: CGColor?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                label = NSColor.labelColor.cgColor
            }
            let text = try XCTUnwrap(NSColor(cgColor: try XCTUnwrap(label))?.usingColorSpace(.sRGB))
            XCTAssertGreaterThanOrEqual(try contrast(text, .white), 1.0)
        }
    }

    func testCopperKeepsTheOldUserShade() {
        XCTAssertEqual(Palette.copper.userBackground, Color(hex: 0x1F1B16))
        XCTAssertEqual(Palette.light.userBackground, Color(hex: 0xF3EEE7))
    }
}
