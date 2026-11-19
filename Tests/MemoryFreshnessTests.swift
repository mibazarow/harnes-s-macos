import XCTest
@testable import Harness

/// R34.1: fresh and corrected records are labelled without reordering the block.
final class MemoryFreshnessTests: XCTestCase {
    private func item(
        _ id: Int64,
        createdDaysAgo: Int,
        supersedes: Int64? = nil
    ) -> MemoryItem {
        MemoryItem(
            id: id, scope: "user", content: "Запись \(id)", kind: "fact", tags: [],
            createdAt: ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(-Double(createdDaysAgo) * 86_400)
            ),
            pinned: false, hits: 0, lastUsedAt: nil, area: "fact",
            supersedesID: supersedes
        )
    }

    func testFreshRecordIsLabelled() {
        XCTAssertEqual(MemoryFreshness.label(item(1, createdDaysAgo: 2), now: Date()),
                       MemoryFreshness.fresh)
    }

    func testOldRecordIsNotLabelled() {
        XCTAssertNil(MemoryFreshness.label(item(1, createdDaysAgo: 30), now: Date()))
    }

    func testReplacementIsLabelledUpdated() {
        XCTAssertEqual(
            MemoryFreshness.label(item(2, createdDaysAgo: 30, supersedes: 1), now: Date()),
            MemoryFreshness.updated
        )
    }

    func testLabelsAreCappedSoTheBlockCannotGrow() {
        let items = (1...10).map { item(Int64($0), createdDaysAgo: 1) }
        let labels = MemoryFreshness.labels(items)
        XCTAssertEqual(labels.count, MemoryFreshness.maxLabels)
        let growth = labels.values.reduce(0) { $0 + $1.count + 1 }
        XCTAssertLessThanOrEqual(growth, 40)
    }

    func testOrderOfRecordsIsUnchanged() {
        let items = [item(3, createdDaysAgo: 1), item(1, createdDaysAgo: 30)]
        let labels = MemoryFreshness.labels(items)
        XCTAssertNotNil(labels[3])
        XCTAssertNil(labels[1])
        XCTAssertEqual(items.map(\.id), [3, 1], "метка не переставляет записи")
    }

    func testUnparsableDateGetsNoLabel() {
        let broken = MemoryItem(
            id: 9, scope: "user", content: "Запись", kind: "fact", tags: [],
            createdAt: "не дата", pinned: false, hits: 0, lastUsedAt: nil, area: "fact"
        )
        XCTAssertNil(MemoryFreshness.label(broken, now: Date()))
    }
}
