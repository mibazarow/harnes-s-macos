import XCTest
@testable import Harness

/// A duplicate key in a schema literal does not fail the build: Swift keeps the last
/// value and only traps inside `Dictionary.init(dictionaryLiteral:)` at first use, which
/// is the first turn of a session. The crash log then points at `definitions` line 6 and
/// names no tool, so this test names it instead.
final class ToolDefinitionsTests: XCTestCase {
    func testNoDuplicateSchemaKeys() {
        let duplicates = ToolRegistry.duplicateSchemaKeys()
        XCTAssertTrue(duplicates.isEmpty, "Повтор ключа в схеме: \(duplicates.joined(separator: "; "))")
    }

    func testEveryDefinitionHasANameAndSchema() {
        for definition in ToolRegistry.definitions {
            XCTAssertFalse(definition.name.isEmpty)
            let type = definition.parameters["type"]?.value as? String
            XCTAssertEqual(type, "object", "Схема \(definition.name) не object")
            XCTAssertNotNil(definition.parameters["properties"], "У \(definition.name) нет properties")
        }
    }
}
