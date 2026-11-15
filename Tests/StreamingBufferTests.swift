import XCTest
@testable import Harness

/// The paint buffer was added without tests. Every one of these assertions guards an
/// invariant that a later refactor could break silently: a missing flush looks like a
/// slightly truncated answer, not like an error.
@MainActor
final class StreamingBufferTests: XCTestCase {
    private func store() -> ChatStore { ChatStore() }

    func testPendingTextIsPartOfTheAnswerBeforePaint() {
        let store = ChatStore()
        let id = store.appendAssistant()
        store.append("привет", to: id)
        store.flushTask?.cancel()

        XCTAssertEqual(store.messageText(of: id), "привет")
        XCTAssertEqual(store.messages.last?.text, "", "до flush пузырь ещё не тронут")
    }

    func testFlushPaintsTheBuffer() {
        let store = ChatStore()
        let id = store.appendAssistant()
        store.append("привет", to: id)
        store.flushTask?.cancel()

        store.flush()

        XCTAssertEqual(store.messages.last?.text, "привет")
        XCTAssertTrue(store.pendingText.isEmpty)
    }

    func testSettleFlushesBeforeUsingTheText() {
        let store = ChatStore()
        let id = store.appendAssistant()
        store.append("хвост ответа", to: id)
        store.flushTask?.cancel()

        XCTAssertTrue(store.settle(id))
        XCTAssertEqual(store.messages.last?.text, "хвост ответа")
    }

    func testFinishFlushesTheTail() {
        let store = ChatStore()
        let id = store.appendAssistant()
        store.append("последние слова", to: id)
        store.flushTask?.cancel()

        store.finish(id)

        XCTAssertTrue(store.messages.last?.text.contains("последние слова") == true)
        XCTAssertFalse(store.isStreaming)
    }

    func testStopFlushesTheTail() {
        let store = ChatStore()
        let id = store.appendAssistant()
        store.append("остановлено на этом", to: id)
        store.flushTask?.cancel()

        store.stop()

        XCTAssertTrue(store.messages.last?.text.contains("остановлено на этом") == true)
        XCTAssertTrue(store.pendingText.isEmpty)
    }

    func testTrimLoopFlushesThenCuts() {
        let store = ChatStore()
        let id = store.appendAssistant()
        let unit = "повторяющийся фрагмент "
        store.append(String(repeating: "x", count: 300) + String(repeating: unit, count: 12), to: id)
        store.flushTask?.cancel()

        store.trimLoop(id)

        XCTAssertTrue(store.pendingText.isEmpty)
        let text = store.messages.last?.text ?? ""
        XCTAssertFalse(text.isEmpty)
        XCTAssertLessThan(text.count, 300 + unit.count * 12)
    }
}
