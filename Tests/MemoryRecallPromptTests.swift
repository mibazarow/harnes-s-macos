import XCTest
@testable import Harness

/// R32.1: the prompt has to say out loud that a question about what was already done
/// starts with a memory lookup, not with a guess.
final class MemoryRecallPromptTests: XCTestCase {
    func testPromptRequiresSearchBeforeAnsweringAboutThePast() {
        let text = Prompts.system
        XCTAssertTrue(text.contains("call `memory_search` first"), "правило поиска отсутствует")
        XCTAssertTrue(text.contains("last time"), "не названы признаки вопроса")
        XCTAssertTrue(text.contains("is it done"), "не назван вопрос о сделанном")
    }

    func testRuleStaysShort() {
        // One paragraph, not a manual: the memory section is already long.
        let lines = Prompts.system.split(separator: "\n").filter {
            $0.contains("call `memory_search` first")
        }
        XCTAssertEqual(lines.count, 1, "правило должно быть одним абзацем")
    }
}
