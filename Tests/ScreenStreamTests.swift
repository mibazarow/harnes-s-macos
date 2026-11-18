import XCTest
@testable import Harness

/// R25.7: change detection is pure; the capture loop is opt-in and needs a grant.
final class ScreenStreamTests: XCTestCase {
    private func frame(_ value: UInt8) -> [UInt8] {
        [UInt8](repeating: value, count: ScreenStream.gridWidth * ScreenStream.gridHeight)
    }

    func testIdenticalFramesHaveNoRegions() {
        XCTAssertTrue(ScreenStream.changedBlocks(frame(120), frame(120)).isEmpty)
    }

    func testASmallDifferenceBelowToleranceIsIgnored() {
        var current = frame(120)
        current[5] = 125

        XCTAssertTrue(ScreenStream.changedBlocks(frame(120), current, tolerance: 8).isEmpty)
    }

    func testChangedBlockIsReportedAtItsPlace() {
        var current = frame(0)
        // Row 3, column 7.
        current[3 * ScreenStream.gridWidth + 7] = 255

        let regions = ScreenStream.changedBlocks(frame(0), current)

        XCTAssertEqual(regions.count, 1)
        let region = try? XCTUnwrap(regions.first)
        XCTAssertEqual(region?.minX ?? -1, 7.0 / Double(ScreenStream.gridWidth), accuracy: 0.0001)
        XCTAssertEqual(region?.minY ?? -1, 3.0 / Double(ScreenStream.gridHeight), accuracy: 0.0001)
    }

    func testMismatchedSizesAreIgnored() {
        XCTAssertTrue(ScreenStream.changedBlocks(frame(0), [0, 1, 2]).isEmpty)
    }

    func testStreamWithoutAWindowIsRefused() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = try? await tools.screenshot(["stream": true])
        XCTAssertEqual(result?.isError, true)
        XCTAssertTrue(result?.output.contains("window") ?? false, result?.output ?? "")
    }
}
