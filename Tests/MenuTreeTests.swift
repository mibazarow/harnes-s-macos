import XCTest
@testable import Harness

/// R18.2 menus: paths are resolved by localized titles, never by index.
final class MenuTreeTests: XCTestCase {
    private var tree: MenuNode {
        MenuNode(title: "bar", enabled: true, children: [
            MenuNode(title: "Файл", enabled: true, children: [
                MenuNode(title: "Экспорт", enabled: true, children: [
                    MenuNode(title: "PDF", enabled: true, children: [])
                ]),
                MenuNode(title: "", enabled: true, children: [])
            ])
        ])
    }

    func testListSkipsSeparatorsAndShowsPaths() {
        let rows = tree.listed()
        XCTAssertTrue(rows.contains("Файл"), rows.joined(separator: "|"))
        XCTAssertTrue(rows.contains("  Файл > Экспорт"), rows.joined(separator: "|"))
        XCTAssertFalse(rows.contains { $0.hasSuffix("> ") })
    }

    func testResolveIsCaseAndDiacriticInsensitive() {
        XCTAssertEqual(tree.resolve(["файл", "экспорт", "pdf"])?.last?.title, "PDF")
        XCTAssertNil(tree.resolve(["Файл", "Нет такого"]))
        XCTAssertNil(tree.resolve([]))
    }
}
