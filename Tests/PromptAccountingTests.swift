import XCTest
@testable import Harness

/// R15: the log must name every part of the request, and the estimate of a tool pair
/// must match the JSON the provider actually receives.
final class PromptAccountingTests: XCTestCase {
    func testBreakdownSumsEveryPart() {
        let breakdown = PromptBreakdown(
            system: 3_000, tools: 5_187, summary: 1_200, history: 40_000, images: 1_100, messages: 7
        )

        XCTAssertEqual(breakdown.total, 50_487)
        let line = breakdown.line
        for part in ["system=3000", "tools=5187", "summary=1200", "history=40000",
                     "images=1100", "total_est=50487", "messages=7"] {
            XCTAssertTrue(line.contains(part), line)
        }
    }

    func testBreakdownWithoutAPhaseKeepsTheOldLine() {
        let breakdown = PromptBreakdown(
            system: 1, tools: 2, summary: 3, history: 4, images: 5, messages: 6
        )
        XCTAssertFalse(breakdown.line.contains("phase="), breakdown.line)
    }

    /// R15.8: the pre-prune line must describe a larger history than the plan that
    /// goes out, and it must say which state it describes.
    @MainActor
    func testPrePruneBreakdownIsLargerThanThePrunedPlan() {
        let output = String(repeating: "z", count: 4_000)
        let old = (0..<3).map { index in
            ChatMessage(role: .assistant, text: "шаг", exchanges: (0..<5).map { offset in
                ToolExchange(
                    callID: "old_\(index)_\(offset)", name: "bash", arguments: "{}",
                    output: output, isError: false
                )
            })
        }
        let recent = (0..<6).map { index in
            ChatMessage(role: .assistant, text: "шаг", exchanges: [ToolExchange(
                callID: "recent_\(index)", name: "bash", arguments: "{}",
                output: String(repeating: "y", count: 500), isError: false
            )])
        }
        var messages: [ChatMessage] = [ChatMessage(role: .user, text: "задача")]
        messages.append(contentsOf: old)
        messages.append(ChatMessage(
            role: .assistant, text: String(repeating: "использовал результаты ", count: 20)
        ))
        messages.append(contentsOf: recent)
        messages.append(ChatMessage(role: .user, text: "продолжай"))

        let chat = ChatStore()
        chat.messages = messages
        let plan = chat.plannedPruning()
        XCTAssertFalse(plan.replacements.isEmpty)

        let pre = chat.prePruneBreakdown(system: "система")
        let pruned = chat.promptMessages(pruning: plan.replacements).reduce(0) { $0 + $1.tokens }

        XCTAssertGreaterThan(pre.history, pruned, "до прунинга история обязана быть больше")
        XCTAssertTrue(pre.line.contains("phase=pre_prune"), pre.line)
        XCTAssertTrue(pre.line.contains("total_est=\(pre.total)"), pre.line)
    }

    func testToolPairEstimateMatchesProviderJSON() throws {
        let id = "call_abc12345"
        let name = "bash"
        let arguments = #"{"command":"ls -la"}"#
        let output = "total 8\ndrwxr-xr-x  2 user  staff  64 Nov 15 10:00 ."

        // The exact shape ProviderClient encodes.
        let payload: [String: Any] = [
            "messages": [
                [
                    "role": "assistant",
                    "tool_calls": [[
                        "id": id,
                        "type": "function",
                        "function": ["name": name, "arguments": arguments]
                    ]]
                ],
                ["role": "tool", "tool_call_id": id, "content": output]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let wire = TokenEstimator.tokens(in: String(decoding: data, as: UTF8.self))
        let estimate = ToolCost.exchange(name: name, arguments: arguments, output: output, id: id)

        let ratio = Double(estimate) / Double(max(wire, 1))
        XCTAssertEqual(ratio, 1.0, accuracy: 0.03, "оценка \(estimate) против JSON \(wire)")
    }

    func testToolCostIncludesTheCallEnvelope() {
        let flat = TokenEstimator.tokens(in: "bash" + #"{"command":"ls"}"#)
        let measured = ToolCost.call(name: "bash", arguments: #"{"command":"ls"}"#)
        XCTAssertGreaterThan(measured, flat, "id, type и function стоят токенов")
    }

    // MARK: - Pressure

    func testEstimateAloneDecidesWhenThereIsNoMeasurement() {
        let decision = PromptPressure.decide(
            estimated: 80_000, measured: nil, usable: 108_800, threshold: 87_040
        )
        XCTAssertEqual(decision.source, .estimate)
        XCTAssertFalse(decision.overThreshold)
    }

    func testProviderMeasurementWinsWhenItExceedsTheEstimateBy20Percent() {
        let decision = PromptPressure.decide(
            estimated: 80_000, measured: 100_000, usable: 108_800, threshold: 87_040
        )
        XCTAssertEqual(decision.tokens, 100_000)
        XCTAssertEqual(decision.source, .measured)
        XCTAssertTrue(decision.overThreshold, "без факта компактация бы не сработала")
    }

    func testSmallDivergenceStaysWithTheEstimate() {
        let decision = PromptPressure.decide(
            estimated: 80_000, measured: 85_000, usable: 108_800, threshold: 87_040
        )
        XCTAssertEqual(decision.source, .estimate)
        XCTAssertEqual(decision.tokens, 80_000)
    }
}
