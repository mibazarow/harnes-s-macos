import XCTest
@testable import Harness

/// S2: status by number, and an archive so a finished child is not "not found".
final class SubagentStatusTests: XCTestCase {
    private func child(
        _ id: String,
        title: String = "читает TASKS.md",
        started: TimeInterval = 0,
        finished: TimeInterval? = nil
    ) -> SubagentRegistry.Child {
        SubagentRegistry.Child(
            id: id, parent: SubagentRegistry.root, depth: 1, title: title,
            startedAt: Date(timeIntervalSince1970: started),
            step: 4, maxSteps: 12, calls: 11,
            lastTool: "fs_read", lastToolAt: Date(timeIntervalSince1970: started + 100),
            cancelled: false, reason: nil,
            finishedAt: finished.map { Date(timeIntervalSince1970: $0) },
            outcome: finished == nil ? nil : "3 файла, 12 пунктов"
        )
    }

    func testLiveDetailNamesStepAndLastTool() {
        let text = SubagentStatus.detail(
            child("agent-2", started: 1_000),
            now: Date(timeIntervalSince1970: 1_107)
        )
        XCTAssertTrue(text.hasPrefix("agent-2 · работает 1:47 · шаг 4/12 · 11 вызовов"), text)
        XCTAssertTrue(text.contains("задача: читает TASKS.md"), text)
        XCTAssertTrue(text.contains("последний инструмент: fs_read"), text)
    }

    func testFinishedDetailShowsOutcomeNotRunning() {
        let text = SubagentStatus.detail(
            child("agent-2", started: 1_000, finished: 1_107),
            now: Date(timeIntervalSince1970: 9_999)
        )
        XCTAssertTrue(text.contains("завершён 1:47"), text)
        XCTAssertTrue(text.contains("итог: 3 файла, 12 пунктов"), text)
        XCTAssertFalse(text.contains("работает"), text)
    }

    func testDurationFormatting() {
        XCTAssertEqual(SubagentStatus.duration(107), "1:47")
        XCTAssertEqual(SubagentStatus.duration(3_723), "1:02:03")
        XCTAssertEqual(SubagentStatus.duration(-5), "0:00")
    }

    func testStatusToolReadsByIdAndIncludesFinishedOnRequest() async throws {
        let registry = SubagentRegistry()
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil,
            subagents: registry, callerID: SubagentRegistry.root
        )
        let ticket = try await registry.begin(parent: SubagentRegistry.root, title: "читает")
        await registry.update(ticket.id, step: 3, lastTool: "fs_read")

        let live = await tools.subagentStatus(["id": ticket.id])
        XCTAssertFalse(live.isError, live.output)
        XCTAssertTrue(live.output.contains("шаг 3/12"), live.output)

        await registry.end(ticket.id, outcome: "готово")
        let finished = await tools.subagentStatus(["id": ticket.id])
        XCTAssertFalse(finished.isError, finished.output)
        XCTAssertTrue(finished.output.contains("завершён"), finished.output)

        let missing = await tools.subagentStatus(["id": "agent-9"])
        XCTAssertTrue(missing.isError)
    }

    func testArchiveKeepsOnlyEightMostRecent() async throws {
        let registry = SubagentRegistry()
        var ids: [String] = []
        for _ in 0..<9 {
            let ticket = try await registry.begin(parent: SubagentRegistry.root)
            ids.append(ticket.id)
            await registry.end(ticket.id, outcome: "ok")
        }
        let archived = await registry.snapshot(includingFinished: true)
        XCTAssertEqual(archived.count, 8, "архив ограничен восемью")
        XCTAssertFalse(archived.contains { $0.id == ids.first }, "самый старый вытеснен")
        XCTAssertTrue(archived.contains { $0.id == ids.last })
        let live = await registry.snapshot()
        XCTAssertTrue(live.isEmpty, "snapshot() показывает только живых")
    }

    func testFinishedChildIsNotLive() async throws {
        let registry = SubagentRegistry()
        let ticket = try await registry.begin(parent: SubagentRegistry.root)
        await registry.end(ticket.id)
        let live = await registry.snapshot()
        XCTAssertTrue(live.isEmpty)
        let cancelled = await registry.isCancelled(ticket.id)
        XCTAssertFalse(cancelled)
        let stillReadable = await registry.child(ticket.id)
        XCTAssertNotNil(stillReadable, "по номеру после финиша статус ещё читается")
    }

    func testReportDoesNotEnterParentContext() {
        // `.system` rows are filtered by promptMessages, so a report cannot leak.
        let report = ChatMessage(
            role: .system,
            text: ChatMessage.subagentReportMarker("agent-1") + "\nнайдено 3 файла"
        )
        XCTAssertEqual(report.subagentReportID, "agent-1")
        XCTAssertEqual(report.role, .system)
    }
}

/// S4: the header renders `ChatStore.runningSubagents`, never the actor.
@MainActor
final class SubagentPillDataTests: XCTestCase {
    func testRunningListFollowsStartAndFinish() async throws {
        let chat = ChatStore()
        XCTAssertTrue(chat.runningSubagents.isEmpty)

        let ticket = try await chat.subagents.begin(
            parent: SubagentRegistry.root, title: "читает TASKS.md"
        )
        await chat.refreshRunningSubagents()
        XCTAssertEqual(chat.runningSubagents.map(\.id), [ticket.id])
        XCTAssertEqual(chat.runningSubagents.first?.title, "читает TASKS.md")

        await chat.subagents.end(ticket.id)
        await chat.refreshRunningSubagents()
        XCTAssertTrue(chat.runningSubagents.isEmpty, "отработал — пилюля исчезла")
    }

    func testPillShowsAtMostThreeAndCountsTheRest() {
        XCTAssertEqual(SubagentPills.visibleLimit, 3)
        let agents = (1...5).map {
            SubagentInfo(SubagentRegistry.Child(
                id: "agent-\($0)", parent: SubagentRegistry.root, depth: 1,
                title: "задача \($0)", startedAt: Date(),
                step: 0, maxSteps: 12, calls: 0, lastTool: nil, lastToolAt: nil,
                cancelled: false, reason: nil, finishedAt: nil, outcome: nil
            ))
        }
        XCTAssertEqual(agents.prefix(SubagentPills.visibleLimit).count, 3)
        XCTAssertEqual(agents.count - SubagentPills.visibleLimit, 2)
    }
}
