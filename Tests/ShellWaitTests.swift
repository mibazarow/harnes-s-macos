import XCTest
@testable import Harness

/// R17: the shell wait is event-driven — exit and cancellation both signal the
/// semaphore — instead of waking up twenty times a second to re-check flags.
final class ShellWaitTests: XCTestCase {
    private let cwd = URL(fileURLWithPath: NSTemporaryDirectory())

    func testCommandRunsAndReturnsItsExitCode() throws {
        let output = try ToolRegistry.runSync("echo hi", cwd: cwd, timeout: 10)
        XCTAssertTrue(output.hasPrefix("exit 0\n"), output)
        XCTAssertTrue(output.contains("hi"), output)
    }

    func testTimeoutStillReportsTheSameMessage() {
        XCTAssertThrowsError(try ToolRegistry.runSync("sleep 5", cwd: cwd, timeout: 0.3)) { error in
            XCTAssertTrue(
                error.localizedDescription.contains("превысила таймаут"),
                error.localizedDescription
            )
        }
    }

    func testCancellationWakesTheWaitWithoutWaitingForTheTimeout() throws {
        let cancellation = ProcessCancellation()
        let started = Date()

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            cancellation.cancel()
        }

        XCTAssertThrowsError(
            try ToolRegistry.runSync("sleep 30", cwd: cwd, timeout: 30, cancellation: cancellation)
        ) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 3, "отмена должна будить ожидание сразу, а не по таймауту")
    }

    func testCancelBeforeTheWaitIsNotLost() throws {
        let cancellation = ProcessCancellation()
        cancellation.cancel()

        XCTAssertThrowsError(
            try ToolRegistry.runSync("sleep 30", cwd: cwd, timeout: 30, cancellation: cancellation)
        ) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }
}
