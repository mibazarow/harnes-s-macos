import XCTest
@testable import Harness

/// D5: a fold that dies mid-way must leave a detectable start without its end.
final class CompactionLockTests: XCTestCase {
    func testLockSurvivesFailedFoldAndIsRecoveredOnNextStart() async throws {
        let database = try AppDatabase(inMemory: true)
        let service = CompactionService()
        try await service.beginLock(turn: 7, database: database)

        let lock = try await service.loadLock(database: database)
        XCTAssertEqual(lock?.turn, 7)
        XCTAssertEqual(lock?.boundaryAtStart, 0)

        // The fold threw: nothing moved, the lock is still there.
        let orphan = try await service.recoverOrphanedLock(database: database)
        XCTAssertEqual(orphan?.turn, 7, "незавершённая попытка должна быть обнаружена")
        let afterRecovery = try await service.loadLock(database: database)
        XCTAssertNil(afterRecovery, "lock снят после отчёта")
    }

    func testLockClearedAfterBoundaryLandedIsNotReported() async throws {
        let database = try AppDatabase(inMemory: true)
        let service = CompactionService()
        try await service.beginLock(turn: 3, database: database)
        // The crash happened after the checkpoint was written but before cleanup.
        try await service.saveSummarizedUpTo(42, database: database)

        let reported = try await service.recoverOrphanedLock(database: database)
        XCTAssertNil(reported)
        let remaining = try await service.loadLock(database: database)
        XCTAssertNil(remaining)
    }

    func testClearLockRemovesIt() async throws {
        let database = try AppDatabase(inMemory: true)
        let service = CompactionService()
        try await service.beginLock(turn: 1, database: database)
        try await service.clearLock(database: database)
        let cleared = try await service.loadLock(database: database)
        XCTAssertNil(cleared)
        let orphan = try await service.recoverOrphanedLock(database: database)
        XCTAssertNil(orphan)
    }

    func testOrphanLogLineNamesTheStartTime() {
        let line = CompactionLog.orphaned(at: "2026-11-25T12:00:00Z")
        XCTAssertEqual(line, "compaction: orphaned lock from 2026-11-25T12:00:00Z")
    }
}
