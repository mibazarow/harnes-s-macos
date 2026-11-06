import XCTest
@testable import Harness

final class CommandCatalogTests: XCTestCase {
    func testSlashShowsEveryCommand() {
        let items = CommandCatalog.suggestions(for: "/")
        XCTAssertEqual(items.count, CommandCatalog.all.count)
        XCTAssertTrue(items.contains { $0.title == "/memory" })
    }

    func testPrefixFiltersCommands() {
        let items = CommandCatalog.suggestions(for: "/mem")
        XCTAssertEqual(items.map(\.title), ["/memory", "/remember"].filter { $0.hasPrefix("/mem") })
        XCTAssertTrue(items.allSatisfy { $0.title.hasPrefix("/mem") })
    }

    func testNamespaceOpensSubcommands() {
        let items = CommandCatalog.suggestions(for: "/memory ")
        XCTAssertTrue(items.contains { $0.title == "/memory search" })
        XCTAssertTrue(items.contains { $0.title == "/memory forget" })

        let filtered = CommandCatalog.suggestions(for: "/memory s")
        XCTAssertEqual(filtered.map(\.title), ["/memory search"])
    }

    func testExactMatchHidesPalette() {
        // Otherwise Enter would keep re-picking the same row and never send.
        XCTAssertTrue(CommandCatalog.suggestions(for: "/clear").isEmpty)
        XCTAssertTrue(CommandCatalog.suggestions(for: "/remember ").isEmpty)
    }

    func testInsertionTextIsReadyToUse() {
        let memory = CommandCatalog.suggestions(for: "/memory ").first { $0.title == "/memory search" }
        XCTAssertEqual(memory?.insert, "/memory search ")

        let clear = CommandCatalog.suggestions(for: "/cle").first
        XCTAssertEqual(clear?.insert, "/clear")
    }

    func testNoSuggestionsForPlainText() {
        XCTAssertTrue(CommandCatalog.suggestions(for: "привет").isEmpty)
        XCTAssertTrue(CommandCatalog.suggestions(for: "/clear\nвторая строка").isEmpty)
    }

    func testHelpMentionsEveryCommand() {
        let help = CommandCatalog.helpText
        for command in CommandCatalog.all {
            XCTAssertTrue(help.contains(command.name), "нет \(command.name)")
            for sub in command.subcommands {
                XCTAssertTrue(help.contains("\(command.name) \(sub.name)"), "нет \(command.name) \(sub.name)")
            }
        }
    }
}
