import AppKit
import XCTest
@testable import Harness

/// R18.4/R18.7: combos parse without posting, and clipboard helpers work on a board
/// that is not the user's.
final class InputPrimitivesTests: XCTestCase {
    func testCombosParse() {
        let save = KeyComboParser.parse("cmd+shift+4")
        XCTAssertEqual(save?.key, 21)
        XCTAssertEqual(save?.flags.contains(.maskCommand), true)
        XCTAssertEqual(save?.flags.contains(.maskShift), true)

        XCTAssertEqual(KeyComboParser.parse("Esc")?.key, 53)
        XCTAssertEqual(KeyComboParser.parse("ctrl+alt+delete")?.key, 51)
        XCTAssertEqual(KeyComboParser.parse("f5")?.key, 96)
    }

    func testBadCombosAreRejected() {
        XCTAssertNil(KeyComboParser.parse("cmd+cmd+a"))
        XCTAssertNil(KeyComboParser.parse("hyper+a"))
        XCTAssertNil(KeyComboParser.parse("cmd+"))
        XCTAssertNil(KeyComboParser.parse(""))
        XCTAssertNil(KeyComboParser.parse("cmd+несуществующая"))
    }

    func testClipboardHelpersUseTheGivenBoard() {
        let board = NSPasteboard(name: .init("harness-test-\(UUID().uuidString)"))
        XCTAssertEqual(Clipboard.types(board), "Буфер пуст.")

        XCTAssertTrue(Clipboard.write("привет", to: board).contains("6"))
        XCTAssertTrue(Clipboard.summary(board).contains("привет"))
        XCTAssertTrue(Clipboard.types(board).contains("public.utf8-plain-text"))

        board.clearContents()
        XCTAssertEqual(Clipboard.types(board), "Буфер пуст.")
    }
}
