import XCTest
@testable import Harness

final class LoopGuardTests: XCTestCase {
    private func step(_ guardValue: inout LoopGuard, _ call: String, _ progress: String) -> Bool {
        guardValue.record(callSignature: call, progressSignature: progress)
    }

    func testIdenticalStepRepeatsAreStuck() {
        var guardValue = LoopGuard()
        XCTAssertFalse(step(&guardValue, "fs_read(a)", "ok#1"))
        XCTAssertFalse(step(&guardValue, "fs_read(a)", "ok#1"))
        XCTAssertTrue(step(&guardValue, "fs_read(a)", "ok#1"))
    }

    func testProgressingRepeatIsNotStuck() {
        var guardValue = LoopGuard()
        for i in 1...10 {
            XCTAssertFalse(step(&guardValue, "bash(poll)", "ok#\(i)"), "шаг \(i)")
        }
    }

    func testTwoStepCycleIsStuck() {
        var guardValue = LoopGuard()
        XCTAssertFalse(step(&guardValue, "fs_read(a)", "ok#1"))
        XCTAssertFalse(step(&guardValue, "edit_file(a)", "ok#2"))
        XCTAssertFalse(step(&guardValue, "fs_read(a)", "ok#1"))
        XCTAssertTrue(step(&guardValue, "edit_file(a)", "ok#2"), "A B A B — цикл")
    }

    func testThreeStepCycleIsStuck() {
        var guardValue = LoopGuard()
        XCTAssertFalse(step(&guardValue, "fs_read(a)", "ok#1"))
        XCTAssertFalse(step(&guardValue, "edit_file(a)", "ok#2"))
        XCTAssertFalse(step(&guardValue, "bash(test)", "ok#3"))
        XCTAssertFalse(step(&guardValue, "fs_read(a)", "ok#1"))
        XCTAssertFalse(step(&guardValue, "edit_file(a)", "ok#2"))
        XCTAssertTrue(step(&guardValue, "bash(test)", "ok#3"), "A B C A B C — цикл")
    }

    func testCycleWithChangingProgressIsNotStuck() {
        var guardValue = LoopGuard()
        // Same shape, but the test output differs every time: real work is happening.
        XCTAssertFalse(step(&guardValue, "fs_read(a)", "ok#1"))
        XCTAssertFalse(step(&guardValue, "bash(test)", "fail#1"))
        XCTAssertFalse(step(&guardValue, "fs_read(a)", "ok#2"))
        XCTAssertFalse(step(&guardValue, "bash(test)", "fail#2"))
        XCTAssertFalse(step(&guardValue, "fs_read(a)", "ok#3"))
        XCTAssertFalse(step(&guardValue, "bash(test)", "fail#3"))
    }

    func testDifferentWorkIsNotStuck() {
        var guardValue = LoopGuard()
        for i in 1...12 {
            XCTAssertFalse(step(&guardValue, "fs_read(file\(i))", "ok#\(i)"), "шаг \(i)")
        }
    }

    /// Тот самый цикл: один и тот же `bash` с чуть разными аргументами,
    /// на выходе всё то же обрезанное полотно. Формально каждый вызов
    /// уникален, поэтому старые проверки молчат, а прогон жрёт весь бюджет.
    func testThrashingSameToolWithChangingArgsIsStuck() {
        var guardValue = LoopGuard()
        let outputs = ["sed -n '118,197p'", "sed -n '44p'", "grep -n Guard"]
        var fired = false
        for round in 0..<4 {
            for (index, _) in outputs.enumerated() {
                let firedNow = step(&guardValue, "bash(\(outputs[round % 3])\(index))", "bash#0#обрезанный вывод")
                if firedNow { fired = true }
            }
        }
        XCTAssertTrue(fired, "топтание одним инструментом без смены результата должно ловиться")
    }

    /// А вот честная работа тем же инструментом: аргументы меняются и
    /// результат меняется — тут останавливать нельзя.
    func testSameToolWithRealProgressIsNotStuck() {
        var guardValue = LoopGuard()
        for i in 1...12 {
            XCTAssertFalse(step(&guardValue, "bash(cmd\(i))", "bash#0#вывод\(i)"), "шаг \(i)")
        }
    }

    func testWindowKeepsMemoryBounded() {
        var guardValue = LoopGuard(window: 4)
        for i in 1...50 {
            _ = step(&guardValue, "bash(x\(i))", "ok#\(i)")
        }
        // Nothing to assert beyond "did not blow up"; the point is the window trims.
        XCTAssertFalse(step(&guardValue, "bash(final)", "ok#final"))
    }
}

final class TruncationTests: XCTestCase {
    func testTruncationReasons() {
        XCTAssertTrue(AgentLoop.isTruncation("length"))
        XCTAssertTrue(AgentLoop.isTruncation("max_tokens"))
        XCTAssertTrue(AgentLoop.isTruncation("content_filter"))
        XCTAssertFalse(AgentLoop.isTruncation("stop"))
        XCTAssertFalse(AgentLoop.isTruncation("tool_calls"))
    }
}

final class RunOutputBudgetTests: XCTestCase {
    /// R24.2: the budget is applied when a result is inserted; earlier messages are
    /// never rewritten, so the provider's prefix cache survives the threshold.
    func testContentIsCutToOneInsertionWithAMarker() {
        let content = String(repeating: "a", count: 5_000)
        let fitted = AgentLoop.fitToolContent(content, remaining: 1_000)

        XCTAssertLessThanOrEqual(fitted.count, 1_000)
        XCTAssertTrue(fitted.hasSuffix("[обрезано: бюджет прогона]"))
    }

    func testSmallContentIsUntouched() {
        XCTAssertEqual(AgentLoop.fitToolContent("маленький вывод", remaining: 60_000), "маленький вывод")
    }

    func testNoRemainingBudgetGivesAStub() {
        XCTAssertEqual(
            AgentLoop.fitToolContent(String(repeating: "b", count: 10), remaining: 0),
            AgentLoop.runOutputStub
        )
    }
}
