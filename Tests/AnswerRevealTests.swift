import XCTest
@testable import Harness

/// The finished answer is typed out in at most 0.7 s, no matter how long it is.
final class AnswerRevealTests: XCTestCase {
    func testRevealFinishesWithinTheCap() {
        for total in [1, 10, 200, 6_000, 60_000] {
            let step = RevealPace.step(total: total)
            let frames = (total + step - 1) / step
            let seconds = Double(frames) * RevealPace.tick
            XCTAssertLessThanOrEqual(seconds, 0.72, "total=\(total)")
            XCTAssertGreaterThanOrEqual(step * RevealPace.ticks, total, "total=\(total)")
        }
    }

    func testShortAnswerIsTypedCharacterByCharacter() {
        XCTAssertEqual(RevealPace.ticks, 44)
        XCTAssertEqual(RevealPace.step(total: 44), 1)
        XCTAssertEqual(RevealPace.step(total: 45), 2)
    }

    func testStepNeverReturnsZero() {
        XCTAssertEqual(RevealPace.step(total: 0), 1, "пустой текст не должен зацикливать набор")
    }
}
