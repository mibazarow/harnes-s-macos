import SwiftUI
import XCTest
@testable import Harness

/// Smoke tests for the light "Пузыри" layout: the views must lay out in the app's only
/// theme and must not depend on the old bubble or on a palette passed down by hand.
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

    /// R41: every service line uses one size that does not follow the transcript size.
    /// The old mix of `.caption`, `.caption2` and `AppFont.ui(fontSize)` changed the
    /// height of the line between states and made the answer jump.
    func testServiceLinesShareOneStatusSize() {
        XCTAssertEqual(AppFont.statusSize, 11)
        // The spinner is drawn at that size, not scaled from a system control.
        XCTAssertEqual(StatusSpinner().size, AppFont.statusSize)
    }

    func testMessageRowUsesStatusFontForServiceLines() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("UI/Chat/MessageRow.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains(".font(.caption2)"), "статусы больше не caption2")
        XCTAssertTrue(source.contains("AppFont.status()"), "у служебных строк один кегль")
        XCTAssertTrue(source.contains("StatusSpinner()"), "крутилка своя, медная")
        // The old scaled system spinner must be gone from the row.
        XCTAssertFalse(
            source.contains(".scaleEffect(0.6)"),
            "системный ProgressView со scaleEffect убран"
        )
    }

    /// R43: the scroll target must carry the real gap, not a hairline below it, and the
    /// composer must have air above its card.
    func testLastBubbleHasAGapAboveTheComposer() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let transcript = try String(
            contentsOf: root.appendingPathComponent("UI/Chat/TranscriptView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            transcript.contains("frame(height: Spacing.offGrid20)"),
            "нижний спейсер должен нести настоящий зазор, а не волосок"
        )
        XCTAssertFalse(
            transcript.contains(".padding(.vertical, Spacing.offGrid20)"),
            "вертикальный паддинг уводил зазор за кадр"
        )

        let composer = try String(
            contentsOf: root.appendingPathComponent("UI/Chat/ComposerView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            composer.contains(".padding(.top, Spacing.small)"),
            "между кромкой скролла и карточкой поля нужен зазор"
        )
    }

    /// R44: one model list, and the check mark is the choice. No second picker.
    func testSettingsHaveOneModelList() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("UI/Settings/ProvidersSettingsView.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(
            source.contains("Picker(\"Основная модель\""),
            "отдельного пикера основной модели больше нет"
        )
        XCTAssertTrue(
            source.contains("ModelSelection.choices(providers)"),
            "список строится из моделей всех провайдеров"
        )
        XCTAssertTrue(source.contains("settings.mainModel = choice.id"))
        XCTAssertTrue(source.contains("Добавить модель"))
        XCTAssertTrue(source.contains("Сначала добавь провайдера и загрузи его модели."))
    }

    func testProseColumnIsNarrowerThanTheContainer() {
        // Step 6: 1100 pt container, 760 pt prose, code and tables on the full width.
        XCTAssertLessThan(Layout.textColumn, Layout.chatContainer)
        XCTAssertLessThanOrEqual(Layout.textColumn, 760)
        XCTAssertLessThanOrEqual(Layout.chatContainer, 1_100)
    }

    func testTheWholeChatColumnIsCappedInRootView() throws {
        // The window may grow past 1100 pt, the conversation may not. Outside the cap
        // the same paper background continues: no side bands and no rules.
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("App/RootView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(
            source.contains(".frame(maxWidth: Layout.chatContainer"),
            "колонка чата должна упираться в 1100 pt"
        )
        XCTAssertFalse(
            source.contains("tokens.windowBackground"),
            "за колонкой не должно быть отдельного фона"
        )
    }

    func testWindowBackdropIsTheChatPaper() {
        XCTAssertEqual(ThemeTokens.copper.windowBackground, ThemeTokens.copper.contentBackground)
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

    func testThereIsOneThemeAndItIsLight() {
        XCTAssertEqual(ThemeTokens.copper.id, "copper")
        XCTAssertEqual(ThemeTokens.copper.scheme, .light)
    }

    func testBubbleWidthsFollowTheMockup() {
        let container: CGFloat = 1_000
        XCTAssertEqual(Bubble.maxWidth(container: container, isUser: false), container - 50)
        XCTAssertEqual(Bubble.maxWidth(container: container, isUser: true), container * 0.86)
        XCTAssertLessThanOrEqual(
            Bubble.maxWidth(container: container, isUser: true),
            container * 0.86,
            "пузырь пользователя не должен занимать больше 86% контейнера"
        )
    }

    func testMessageRowDoesNotRenderRoleNameOrTime() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("UI/Chat/MessageRow.swift"),
            encoding: .utf8
        )
        XCTAssertFalse(source.contains("message.role.label"), "имя роли убрано")
        XCTAssertFalse(source.contains("message.date"), "время убрано")
        XCTAssertFalse(source.contains("formatted(date:"), "время убрано")
        // The state badges are not role decoration and must stay.
        XCTAssertTrue(source.contains("в очереди"))
        XCTAssertTrue(source.contains("не отправлено"))
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

/// Both roles must be visually distinct bubbles in the light theme, and both must stay
/// readable on their own plate.
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

    func testUserBubbleDiffersFromTheBackground() throws {
        let palette = Palette()
        let bubble = try XCTUnwrap(NSColor(palette.userBackground).usingColorSpace(.sRGB))
        let background = try XCTUnwrap(NSColor(palette.background).usingColorSpace(.sRGB))
        XCTAssertGreaterThan(
            abs(try luminance(bubble) - luminance(background)), 0.005,
            "пузырь пользователя должен быть виден"
        )
    }

    func testAssistantBubbleIsAWhitePlate() throws {
        let palette = Palette()
        let bubble = try XCTUnwrap(NSColor(palette.assistantBubble).usingColorSpace(.sRGB))
        let background = try XCTUnwrap(NSColor(palette.background).usingColorSpace(.sRGB))
        XCTAssertGreaterThan(
            abs(try luminance(bubble) - luminance(background)), 0.005,
            "белый пузырь ответа должен отличаться от бумажного фона"
        )
    }

    func testUserTextStaysReadableOnItsBubble() throws {
        let palette = Palette()
        let text = try XCTUnwrap(NSColor(palette.text).usingColorSpace(.sRGB))
        let bubble = try XCTUnwrap(NSColor(palette.userBackground).usingColorSpace(.sRGB))
        XCTAssertGreaterThanOrEqual(try contrast(text, bubble), 4.5, "текст на пузыре должен читаться")
    }

    func testAccentStrongIsReadableOnEverySurface() throws {
        let palette = Palette()
        let copper = try XCTUnwrap(NSColor(palette.accentStrong).usingColorSpace(.sRGB))
        let surfaces = [
            palette.background,
            palette.panel,
            palette.codeBackground,
            palette.assistantBubble,
            palette.userBackground
        ]
        for surface in surfaces {
            let nsSurface = try XCTUnwrap(NSColor(surface).usingColorSpace(.sRGB))
            XCTAssertGreaterThanOrEqual(
                try contrast(copper, nsSurface), 4.5,
                "медь на именах инструментов и инлайн-коде должна читаться"
            )
        }
    }

    func testLightPaletteKeepsTheBubblesValues() {
        XCTAssertEqual(Palette().userBackground, Color(hex: 0xF3E7D5))
        XCTAssertEqual(Palette().assistantBubble, Color(hex: 0xFFFFFF))
        XCTAssertEqual(Palette().background, Color(hex: 0xFBFAF8))
    }
}
