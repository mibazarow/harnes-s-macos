import XCTest
@testable import Harness

/// R19.0: rare tools travel as a name and one line; the full schema is fetched once and
/// stays for the session.
final class ToolCatalogTests: XCTestCase {
    private func registry(_ catalog: ToolCatalogState = ToolCatalogState()) -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil,
            catalog: catalog
        )
    }

    func testAllToolsAreStillDefined() {
        XCTAssertEqual(ToolRegistry.definitions.count, 83)
        XCTAssertEqual(Set(ToolRegistry.definitions.map(\.name)).count, 83)
    }

    func testDeferredToolIsCompactUntilLoaded() async throws {
        let catalog = ToolCatalogState()
        let tools = registry(catalog)
        let before = await tools.schemas()
        let screenshot = try XCTUnwrap(before.first { $0.name == "screenshot" })

        XCTAssertTrue(screenshot.description.contains("tool_load"), screenshot.description)
        let properties = screenshot.parameters["properties"]?.value as? [String: Any]
        XCTAssertEqual(properties?.count, 0, "у отложенного инструмента схемы ещё нет")

        let loaded = tools.toolLoad(["names": ["screenshot"]])
        XCTAssertFalse(loaded.isError, loaded.output)
        XCTAssertTrue(loaded.output.contains("screenshot:"), loaded.output)
        XCTAssertTrue(catalog.isLoaded("screenshot"))

        let after = await tools.schemas()
        let expanded = try XCTUnwrap(after.first { $0.name == "screenshot" })
        let expandedProperties = expanded.parameters["properties"]?.value as? [String: Any]
        XCTAssertGreaterThan(expandedProperties?.count ?? 0, 0, "после tool_load схема полная")
    }

    func testCoreToolKeepsItsFullSchema() async throws {
        let tools = registry()
        let schemas = await tools.schemas()
        let read = try XCTUnwrap(schemas.first { $0.name == "fs_read" })
        let properties = read.parameters["properties"]?.value as? [String: Any]
        XCTAssertNotNil(properties?["path"])
    }

    func testDeferredToolWithBadJSONGetsItsSchema() async {
        let catalog = ToolCatalogState()
        let tools = registry(catalog)
        let result = await tools.execute(ToolCall(id: "c", name: "screenshot", arguments: "not json"))

        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Схема screenshot не была загружена"), result.output)
        XCTAssertTrue(catalog.isLoaded("screenshot"))
    }

    func testSentCatalogIsCheaperThanTheFullOne() async {
        let compact = await registry().schemaTokenCost()
        let full = ToolRegistry.schemasTokenCost()

        XCTAssertLessThan(compact, full, "compact=\(compact) full=\(full)")
        XCTAssertLessThanOrEqual(compact, Tuning.schemaTokenBudget, "compact=\(compact)")
    }
}

/// D11: one override layer over the built-in catalog.
final class ToolOverridesTests: XCTestCase {
    private func registry(_ catalog: ToolCatalogState) -> ToolRegistry {
        ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil,
            catalog: catalog
        )
    }

    func testDisablingOneToolLeavesTheRest() async {
        let catalog = ToolCatalogState()
        catalog.disable(["fs_read"])
        let schemas = await registry(catalog).schemas()
        XCTAssertFalse(schemas.contains { $0.name == "fs_read" })
        XCTAssertTrue(schemas.contains { $0.name == "fs_list" })
        XCTAssertTrue(schemas.contains { $0.name == "memory_search" })
    }

    func testReplacementChangesTheDefinition() async {
        let catalog = ToolCatalogState()
        var replacement = ToolRegistry.definitions.first { $0.name == "memory_search" }!
        replacement = ToolDefinition(
            name: replacement.name, exposure: .core,
            description: "Подменённое описание", parameters: replacement.parameters
        )
        catalog.replace(replacement)
        let schemas = await registry(catalog).schemas()
        let tool = schemas.first { $0.name == "memory_search" }
        XCTAssertEqual(tool?.description, "Подменённое описание")
    }

    func testDisableThenReplaceRestoresTheTool() async {
        let catalog = ToolCatalogState()
        let base = ToolRegistry.definitions.first { $0.name == "fs_read" }!
        catalog.disable(["fs_read"])
        catalog.replace(base)
        let names = await registry(catalog).schemas().map(\.name)
        XCTAssertTrue(names.contains("fs_read"))
    }

    func testClearingOverridesRestoresEverything() async {
        let catalog = ToolCatalogState()
        catalog.disable(["fs_read", "fs_list"])
        catalog.clearOverrides()
        let names = await registry(catalog).schemas().map(\.name)
        XCTAssertTrue(names.contains("fs_read"))
        XCTAssertTrue(names.contains("fs_list"))
    }
}
