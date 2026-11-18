import XCTest
@testable import Harness

/// The compaction policy: budget arithmetic, manual force, calibration, anti-thrash.
@MainActor
final class CompactionPolicyTests: XCTestCase {
    // MARK: - Budget arithmetic (R12.1 / R12.2)

    func testBudgetReservesOutputAndKeepsThresholdBelowUsable() {
        let composer = ContextComposer()

        let large = composer.budget(for: 128_000, thresholdPercent: 80)
        XCTAssertGreaterThan(large.outputReserve, 16_000)
        XCTAssertEqual(large.usable, 128_000 - large.outputReserve)
        XCTAssertLessThanOrEqual(large.thresholdTokens, large.usable)
        XCTAssertGreaterThan(large.thresholdTokens, large.usable / 2)

        // A small window must not degenerate into "threshold == whole window".
        let small = composer.budget(for: 32_000, thresholdPercent: 80)
        XCTAssertLessThan(small.thresholdTokens, small.usable)
        XCTAssertGreaterThan(small.thresholdTokens, 0)
    }

    func testProtectedPrefixIsNeverFolded() {
        let composer = ContextComposer()
        let messages = (0..<12).map { index in
            ContextMessage(id: index, role: index.isMultiple(of: 2) ? "user" : "assistant",
                           text: "шаг \(index)", tokens: 500)
        }

        let plan = composer.plan(
            systemPrompt: "", messages: messages, contextWindow: 10_000, thresholdPercent: 100
        )

        XCTAssertTrue(plan.didCompact)
        XCTAssertEqual(Array(plan.included.prefix(3)).map(\.id), [0, 1, 2])
        XCTAssertFalse(plan.compacted.contains { $0.id < 3 }, "первые три сообщения не сворачиваются")
    }

    func testEstimateScaleShrinksTheWindow() {
        let composer = ContextComposer()
        let messages = (0..<10).map { index in
            ContextMessage(id: index, role: "user", text: "x", tokens: 500)
        }

        let normal = composer.plan(
            systemPrompt: "", messages: messages, contextWindow: 10_000, thresholdPercent: 100
        )
        let pessimistic = composer.plan(
            systemPrompt: "", messages: messages, contextWindow: 10_000,
            thresholdPercent: 100, estimateScale: 2
        )

        XCTAssertGreaterThanOrEqual(pessimistic.compacted.count, normal.compacted.count)
        XCTAssertLessThan(pessimistic.included.count, normal.included.count + 1)
    }

    // MARK: - Hysteresis (M32)

    func testCompactionLandsAtTargetNotAtTrigger() {
        let composer = ContextComposer()
        let budget = composer.budget(for: 100_000, thresholdPercent: 80)
        XCTAssertEqual(budget.thresholdTokens, 67_200)
        XCTAssertEqual(budget.targetTokens, 50_400)
        XCTAssertLessThan(budget.targetTokens, budget.thresholdTokens)

        // 81% of the usable budget: over the trigger, so one fold to the target.
        let over = (0..<68).map { index in
            ContextMessage(id: index, role: "user", text: "x", tokens: 1_000)
        }
        let plan = composer.plan(
            systemPrompt: "", messages: over, contextWindow: 100_000, thresholdPercent: 80
        )
        XCTAssertTrue(plan.didCompact)
        XCTAssertLessThanOrEqual(plan.usedTokens, budget.targetTokens)

        // The fold must buy headroom: the next message does not cross the trigger again.
        let next = plan.included + [ContextMessage(id: 99, role: "user", text: "x", tokens: 1_000)]
        let second = composer.plan(
            systemPrompt: "", messages: next, contextWindow: 100_000, thresholdPercent: 80
        )
        XCTAssertFalse(second.didCompact, "второй ход после свёртки не должен сжимать снова")
    }

    func testHistoryUnderTheTriggerIsNotFolded() {
        let composer = ContextComposer()
        // 79% of the usable budget: below the trigger.
        let under = (0..<66).map { index in
            ContextMessage(id: index, role: "user", text: "x", tokens: 1_000)
        }
        let plan = composer.plan(
            systemPrompt: "", messages: under, contextWindow: 100_000, thresholdPercent: 80
        )
        XCTAssertFalse(plan.didCompact)
        XCTAssertEqual(plan.included.count, under.count)
    }

    // MARK: - Calibration (R9 / R11.2)

    func testCalibrationClampsAndPersists() async throws {
        let database = try AppDatabase(inMemory: true)
        let calibration = TokenCalibration(database: database)

        await calibration.record(providerID: "p", model: "m", measured: 1_500, estimated: 1_000)
        let scale = await calibration.scale(providerID: "p", model: "m")
        XCTAssertEqual(scale, 1.5, accuracy: 0.001)
        let measured = await calibration.lastMeasured(providerID: "p", model: "m")
        XCTAssertEqual(measured, 1_500)

        // A wild sample is noise, not a reason to halve the window.
        await calibration.record(providerID: "p", model: "m", measured: 9_000, estimated: 1_000)
        let clamped = await calibration.scale(providerID: "p", model: "m")
        XCTAssertEqual(clamped, TokenCalibration.maxScale, accuracy: 0.001)

        // A fresh instance reads the same sample back from app_state.
        let reloaded = TokenCalibration(database: database)
        let persisted = await reloaded.scale(providerID: "p", model: "m")
        XCTAssertEqual(persisted, TokenCalibration.maxScale, accuracy: 0.001)
    }

    // MARK: - Manual compaction (R8)

    func testManualCompactFoldsEvenWhenItFits() async throws {
        let server = try StubSSEServer(responses: [[
            #"{"choices":[{"delta":{"content":"Цель: задача. Следующий шаг: продолжить."}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        ]])
        try server.start()
        defer { server.stop() }

        let database = try AppDatabase(inMemory: true)
        let services = AppServices(database: database)
        _ = try await services.providers.save(ProviderModel(
            id: "p1", name: "stub", baseURL: server.baseURL, apiKey: "k",
            models: ["m"], defaultModel: "m", contextWindow: 128_000, isDefault: true
        ))

        let chat = ChatStore(services: services)
        chat.messages = [
            ChatMessage(role: .user, text: "сделай задачу"),
            ChatMessage(role: .assistant, text: "делаю"),
            ChatMessage(role: .user, text: "продолжай")
        ]

        // The history is tiny: the old code answered "Сжимать нечего: помещается".
        let result = await chat.compactNow()

        XCTAssertTrue(result.contains("История сжата"), result)
        XCTAssertFalse(chat.checkpointSummary.isEmpty)
        XCTAssertNotNil(chat.compactedThroughID)
        XCTAssertTrue(chat.promptMessages.isEmpty, "ручной компакт сворачивает всё")
    }

    // MARK: - Anti-thrash (R12.3)

    func testThreeIneffectiveCompactionsBlockTheAutomaticPath() async throws {
        let database = try AppDatabase(inMemory: true)
        let services = AppServices(database: database)
        let chat = ChatStore(services: services)
        chat.messages = [
            ChatMessage(role: .user, text: "раз"),
            ChatMessage(role: .assistant, text: "два")
        ]

        // "Before" is the size that was supposed to shrink; with an unchanged history
        // the fold was ineffective, which is exactly the loop this guard stops.
        let before = chat.promptMessages.reduce(0) { $0 + $1.tokens }
        for _ in 0..<3 {
            chat.recordCompactionEffectiveness(before: before, services: services)
        }

        let guardState = ChatStore.loadCompactionGuard(services: services)
        XCTAssertEqual(guardState.strikes, 3)
        XCTAssertNotNil(guardState.blockedUntil)

        ChatStore.resetCompactionGuard(services: services)
        let cleared = ChatStore.loadCompactionGuard(services: services)
        XCTAssertEqual(cleared.strikes, 0)
        XCTAssertNil(cleared.blockedUntil)
    }

    // MARK: - Estimate (R11.2)

    func testAgentLoopEstimateCountsToolResultsAndImages() {
        let plain = AgentLoop.estimateTokens(
            messages: [ProviderMessage(role: .user, content: "hello")],
            schemas: []
        )
        let heavy = AgentLoop.estimateTokens(
            messages: [
                ProviderMessage(role: .user, content: "hello"),
                ProviderMessage(role: .tool, content: String(repeating: "x", count: 4_000), toolCallID: "1"),
                ProviderMessage(role: .user, content: "img", images: [Data([0x01])])
            ],
            schemas: []
        )

        XCTAssertGreaterThan(heavy, plain + 1_000)
    }
}
