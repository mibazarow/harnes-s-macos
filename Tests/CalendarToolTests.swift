import XCTest
@testable import Harness

/// R26.1: date parsing, free windows and the "only our events" rule are pure.
final class CalendarToolTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("calendar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CreatedEvents.setStorageOverride(directory.appendingPathComponent("created.json"))
    }

    override func tearDownWithError() throws {
        CreatedEvents.setStorageOverride(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    private func registry() -> ToolRegistry {
        ToolRegistry(
            workspace: directory, memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
    }

    func testISODatesParseWithAndWithoutFraction() {
        XCTAssertNotNil(CalendarDates.parse("2026-11-19T10:00:00+03:00"))
        XCTAssertNotNil(CalendarDates.parse("2026-11-19T07:00:00Z"))
        XCTAssertNotNil(CalendarDates.parse("2026-11-19T07:00:00.500Z"))
        XCTAssertNil(CalendarDates.parse("завтра в 10"))
        XCTAssertNil(CalendarDates.parse(nil))
    }

    func testFreeSlotsSkipBusyBlocks() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let range = FreeBusy.Interval(start: base, end: base.addingTimeInterval(8 * 3600))
        let busy = [
            FreeBusy.Interval(start: base.addingTimeInterval(3600),
                              end: base.addingTimeInterval(2 * 3600)),
            FreeBusy.Interval(start: base.addingTimeInterval(4 * 3600),
                              end: base.addingTimeInterval(4.5 * 3600))
        ]

        let slots = FreeBusy.freeSlots(busy: busy, within: range, duration: 3600)

        XCTAssertEqual(slots.count, 3)
        XCTAssertEqual(slots[0].start, base)
        XCTAssertEqual(slots[0].end, base.addingTimeInterval(3600))
        XCTAssertEqual(slots[1].start, base.addingTimeInterval(2 * 3600))
        XCTAssertEqual(slots[2].start, base.addingTimeInterval(4.5 * 3600))
    }

    func testFreeSlotsMergeOverlappingBusyBlocks() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let range = FreeBusy.Interval(start: base, end: base.addingTimeInterval(4 * 3600))
        let busy = [
            FreeBusy.Interval(start: base, end: base.addingTimeInterval(2 * 3600)),
            FreeBusy.Interval(start: base.addingTimeInterval(3600),
                              end: base.addingTimeInterval(3 * 3600))
        ]

        let slots = FreeBusy.freeSlots(busy: busy, within: range, duration: 1800)

        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0].start, base.addingTimeInterval(3 * 3600))
    }

    func testTooShortWindowIsNotAFreeSlot() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let range = FreeBusy.Interval(start: base, end: base.addingTimeInterval(1800))
        XCTAssertTrue(FreeBusy.freeSlots(busy: [], within: range, duration: 3600).isEmpty)
    }

    func testCreatedEventsRememberOnlyWhatWasCreated() {
        XCTAssertFalse(CreatedEvents.contains("A"))
        CreatedEvents.remember("A")
        XCTAssertTrue(CreatedEvents.contains("A"))
        CreatedEvents.forget("A")
        XCTAssertFalse(CreatedEvents.contains("A"))
    }

    func testDeleteWithoutConfirmIsRefused() async {
        let result = await registry().calendarTool(["action": "delete_event", "id": "X"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
    }

    func testDeleteOfAForeignEventIsRefused() async {
        let result = await registry().calendarTool([
            "action": "delete_event", "id": "SOMEONE-ELSE", "confirm": true
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("не этим инструментом"), result.output)
    }

    func testCreateNeedsISOStart() async {
        let result = await registry().calendarTool([
            "action": "create_event", "title": "Встреча", "start": "завтра в 10"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("ISO-8601"), result.output)
    }

    func testCreateNeedsATitle() async {
        let result = await registry().calendarTool([
            "action": "create_event", "start": "2026-11-19T10:00:00+03:00"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("title"), result.output)
    }
}
