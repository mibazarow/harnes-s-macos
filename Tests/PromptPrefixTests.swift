import XCTest
@testable import Harness

/// M39: the prefix hash is the measurement that tells a real cache win from a lucky one.
final class PromptPrefixTests: XCTestCase {
    private func schema(_ name: String, description: String = "d") -> ProviderToolSchema {
        ProviderToolSchema(
            name: name,
            description: description,
            parameters: [
                "type": AnySendable("object"),
                "properties": AnySendable(["path": ["type": "string"]]),
                "required": AnySendable(["path"])
            ]
        )
    }

    func testSamePrefixProducesSameHash() {
        let tools = [schema("fs_read"), schema("bash")]
        let first = PromptPrefix.hash(system: "system text", tools: tools)
        let second = PromptPrefix.hash(system: "system text", tools: tools)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 16)
    }

    func testChangedSystemChangesHash() {
        let tools = [schema("fs_read")]
        XCTAssertNotEqual(
            PromptPrefix.hash(system: "system text", tools: tools),
            PromptPrefix.hash(system: "system text\n\nСейчас: 12:00", tools: tools)
        )
    }

    func testChangedToolDescriptionChangesHash() {
        XCTAssertNotEqual(
            PromptPrefix.hash(system: "s", tools: [schema("fs_read", description: "old")]),
            PromptPrefix.hash(system: "s", tools: [schema("fs_read", description: "new")])
        )
    }

    func testEmptyInputsStillProduceAStableHash() {
        let first = PromptPrefix.hash(system: "", tools: [])
        XCTAssertEqual(first, PromptPrefix.hash(system: "", tools: []))
        XCTAssertEqual(first.count, 16)
    }
}
