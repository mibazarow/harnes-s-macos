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

    /// R42: a slash is a command only when the first token is exactly a known name.
    /// Paths, API paths and a slash in the middle of a phrase are ordinary text.
    func testOnlyKnownFirstTokenIsACommand() {
        let commands = [
            "/help",
            "/HELP",
            "/search запрос",
            "/clear",
            "/memory list"
        ]
        for text in commands {
            XCTAssertTrue(CommandCatalog.isCommand(text), "должно быть командой: \(text)")
        }

        let plain = [
            "/Users/mb/x.swift",
            "/usr/local/bin",
            "/api/v1/users",
            "текст /посередине",
            "/",
            "//",
            "/helpme",
            "/ ",
            "",
            "привет"
        ]
        for text in plain {
            XCTAssertFalse(CommandCatalog.isCommand(text), "не должно быть командой: \(text)")
        }
    }

    func testCommandNameIsTheLowercasedFirstToken() {
        XCTAssertEqual(CommandCatalog.commandName(of: "/HELP"), "/help")
        XCTAssertEqual(CommandCatalog.commandName(of: "/search запрос"), "/search")
        // Leading whitespace is skipped: `send` trims the text before this is called.
        XCTAssertEqual(CommandCatalog.commandName(of: "  /help"), "/help")
        XCTAssertEqual(CommandCatalog.commandName(of: "/Users/mb"), "/users/mb")
        XCTAssertEqual(CommandCatalog.commandName(of: "/"), nil)
    }

    func testPathGetsNoSuggestions() {
        XCTAssertTrue(CommandCatalog.suggestions(for: "/Users/mb/x.swift").isEmpty)
        XCTAssertTrue(CommandCatalog.suggestions(for: "/usr").isEmpty)
        XCTAssertTrue(CommandCatalog.suggestions(for: "/api/v1/users").isEmpty)
    }
}
