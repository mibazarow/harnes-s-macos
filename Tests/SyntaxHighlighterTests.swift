import SwiftUI
import XCTest
@testable import Harness

final class SyntaxHighlighterTests: XCTestCase {
    private func color(of needle: String, in rendered: AttributedString) -> Color? {
        guard let range = rendered.range(of: needle) else { return nil }
        var cursor = rendered.startIndex
        for run in rendered.runs {
            if run.range.contains(range.lowerBound) {
                _ = cursor
                return run.foregroundColor
            }
            cursor = run.range.upperBound
        }
        return nil
    }

    func testDiffLinesAreColoredByRole() {
        let code = """
        --- a/file.swift
        +++ b/file.swift
        @@ -1,2 +1,2 @@
        -let tail = old
        +let tail = new
         context
        """
        let palette = Palette()
        let rendered = SyntaxHighlighter(language: .diff, palette: palette, fontSize: 13).highlight(code)

        XCTAssertEqual(color(of: "--- a/file.swift", in: rendered), palette.type)
        XCTAssertEqual(color(of: "@@ -1,2 +1,2 @@", in: rendered), palette.keyword)
        XCTAssertEqual(color(of: "-let tail = old", in: rendered), palette.dim)
        XCTAssertEqual(color(of: "+let tail = new", in: rendered), palette.accent)
        XCTAssertEqual(color(of: " context", in: rendered), palette.assistantText)
    }

    func testDiffKeepsEveryLine() {
        let code = "--- a\n+++ b\n-old\n+new"
        let rendered = SyntaxHighlighter(language: .diff, palette: Palette(), fontSize: 13).highlight(code)
        XCTAssertEqual(String(rendered.characters), code)
    }

    func testDiffFenceIsDetectedFromLanguageName() {
        XCTAssertEqual(CodeLanguage.detect("diff"), .diff)
        XCTAssertEqual(CodeLanguage.detect("patch"), .diff)
        XCTAssertEqual(CodeLanguage.detect("swift"), .swift)
        XCTAssertEqual(CodeLanguage.detect("nonsense"), .plain)
    }
}
