import XCTest
@testable import Harness

/// D9: safety is declared by the tool, and the loop reads the declaration.
final class ConcurrencySafeTests: XCTestCase {
    func testReadOnlyToolsAreSafe() {
        for name in ["fs_read", "fs_list", "read_many", "search_code", "memory_search"] {
            XCTAssertTrue(
                ToolRegistry.definitions.first { $0.name == name }?.isConcurrencySafe == true,
                name
            )
        }
    }

    func testMutatingToolsAreNotSafeByDefault() {
        for name in ["fs_write", "edit_file", "bash", "memory_add", "trash_paths"] {
            XCTAssertFalse(
                ToolRegistry.definitions.first { $0.name == name }?.isConcurrencySafe == true,
                name
            )
        }
    }

    func testLoopUsesTheDeclaredSet() {
        XCTAssertEqual(
            AgentLoop.parallelSafeTools,
            ToolRegistry.concurrencySafeNames,
            "цикл не должен иметь собственный список"
        )
    }

    func testNewDefinitionDefaultsToSerialized() {
        let definition = ToolDefinition(
            name: "brand_new", description: "x",
            parameters: ["type": AnySendable("object")]
        )
        XCTAssertFalse(definition.isConcurrencySafe)
    }
}
