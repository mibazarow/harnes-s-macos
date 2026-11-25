import XCTest
@testable import Harness

/// D3: a declared output shape is enforced; a tool cannot quietly return a sentence.
final class ToolOutputContractTests: XCTestCase {
    private func schema() -> [String: AnySendable] {
        [
            "type": AnySendable("object"),
            "properties": AnySendable([
                "id": ["type": "integer"],
                "name": ["type": "string"],
                "ok": ["type": "boolean"],
                "items": ["type": "array"]
            ] as [String: [String: Any]]),
            "required": AnySendable(["id", "name", "ok", "items"])
        ]
    }

    func testValidValuePasses() {
        let value: [String: Any] = ["id": 7, "name": "x", "ok": true, "items": [1, 2]]
        XCTAssertNil(ToolOutputContract.problem(value: value, schema: schema()))
    }

    func testMissingRequiredFieldIsReported() {
        let value: [String: Any] = ["id": 7, "name": "x", "ok": true]
        let problem = ToolOutputContract.problem(value: value, schema: schema())
        XCTAssertEqual(problem, "нет обязательных полей: items")
    }

    func testWrongTypeIsReported() {
        let value: [String: Any] = ["id": "семь", "name": "x", "ok": true, "items": []]
        XCTAssertEqual(ToolOutputContract.problem(value: value, schema: schema()),
                       "id: ожидалось целое")
    }

    func testNonObjectIsReported() {
        XCTAssertNotNil(ToolOutputContract.problem(value: "готово", schema: schema()))
    }

    func testToolDeclaringSchemaWithoutCanonicalValueIsAnError() {
        // `memory_search` declares a schema, so a plain `.ok` must be refused.
        let problem = ToolRegistry.outputProblem(
            tool: "memory_search", result: .ok("просто текст")
        )
        XCTAssertEqual(problem, "каноническое значение отсутствует")
    }

    func testToolWithoutSchemaIsNotChecked() {
        XCTAssertNil(ToolRegistry.outputProblem(tool: "fs_list", result: .ok("любой текст")))
    }

    func testErrorResultsAreNotSchemaChecked() {
        XCTAssertNil(ToolRegistry.outputProblem(tool: "memory_search", result: .fail("нет памяти")))
    }

    func testMemorySearchProducesCanonicalHits() {
        let item = MemoryItem(id: 3, scope: "user", content: "сервер в Казани", kind: "fact",
                              tags: [], createdAt: "2026-11-25", pinned: true, hits: 1,
                              lastUsedAt: nil)
        let result = ToolRegistry.memoryHitsResult(query: "сервер", items: [item], text: "#3 …")
        let value = try? XCTUnwrap(result.canonicalValue?.value as? [String: Any])
        XCTAssertEqual(value?["count"] as? Int, 1)
        let hits = value?["hits"] as? [[String: Any]]
        XCTAssertEqual(hits?.first?["id"] as? Int64, 3)
        XCTAssertEqual(hits?.first?["pinned"] as? Bool, true)
        XCTAssertNil(ToolRegistry.outputProblem(tool: "memory_search", result: result))
    }

    func testProcessEnvelopeIsCanonicalOnlyOnSuccess() {
        let ok = ToolRegistry.canonicalEnvelope(.ok("2 процессов"), action: "list")
        XCTAssertNil(ToolRegistry.outputProblem(tool: "process", result: ok))
        let failure = ToolRegistry.canonicalEnvelope(.fail("нет id"), action: "logs")
        XCTAssertTrue(failure.isError)
        XCTAssertNil(failure.canonicalValue)
    }
}
