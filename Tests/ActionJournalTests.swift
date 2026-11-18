import XCTest
@testable import Harness

/// R30.6: every step leaves a row with its outcome, tokens and cost; the CSV is the
/// archive; arguments are scrubbed before they are stored.
final class ActionJournalTests: XCTestCase {
    private var database: AppDatabase!
    private var journal: ActionJournal!

    override func setUpWithError() throws {
        database = try AppDatabase(inMemory: true)
        journal = ActionJournal(database: database)
    }

    private func draft(tool: String, args: String, outcome: String = "done",
                       prompt: Int = 0, completion: Int = 0, cost: Double = 0) -> ActionJournal.Draft {
        ActionJournal.Draft(
            sessionID: "session", messageID: "message", step: 1, tool: tool, args: args,
            outcome: outcome, model: "local", promptTokens: prompt,
            completionTokens: completion, costUSD: cost,
            becauseKind: "message", becauseQuote: "проверь сборку"
        )
    }

    func testThreeStepsLeaveThreeRows() async throws {
        try await journal.record(draft(tool: "fs_read", args: #"{"path":"a.txt"}"#))
        try await journal.record(draft(tool: "bash", args: #"{"command":"make"}"#))
        try await journal.record(draft(tool: "model", args: "", prompt: 900, completion: 40,
                                       cost: 0.0012))

        let entries = try await journal.list()
        let count = try await journal.count()

        XCTAssertEqual(count, 3)
        XCTAssertEqual(entries.map(\.tool), ["model", "bash", "fs_read"])
        XCTAssertEqual(entries[0].promptTokens, 900)
        XCTAssertEqual(entries[0].costUSD, 0.0012, accuracy: 0.000001)
        XCTAssertEqual(entries[1].outcome, "done")
        XCTAssertEqual(entries[0].becauseQuote, "проверь сборку")
    }

    func testSecretInArgumentsIsScrubbed() async throws {
        try await journal.record(draft(
            tool: "secret_save",
            args: #"{"alias":"api","value":"sk-live-abcdef","token=deadbeefcafebabe0123456789abcdef"}"#
        ))

        let entries = try await journal.list()
        let entry = try XCTUnwrap(entries.first)
        XCTAssertFalse(entry.argsSummary.contains("deadbeefcafebabe0123456789abcdef"),
                       entry.argsSummary)
        XCTAssertTrue(entry.argsSummary.contains("<redacted>"), entry.argsSummary)
    }

    func testSummaryIsCappedAtTwoHundredCharacters() {
        let long = String(repeating: "x", count: 1_000)
        XCTAssertEqual(ActionJournal.summary(long).count, 200)
    }

    func testExportWritesHeaderAndRows() async throws {
        try await journal.record(draft(tool: "fs_read", args: "{}"))
        try await journal.record(draft(tool: "bash", args: #"{"command":"ls"}"#))
        try await journal.record(draft(tool: "model", args: "", prompt: 10, completion: 5))

        let url = try await journal.export(
            from: Date().addingTimeInterval(-60), to: Date().addingTimeInterval(60)
        )
        defer { try? FileManager.default.removeItem(at: url) }
        let csv = try String(contentsOf: url, encoding: .utf8)
        let lines = csv.split(separator: "\n")

        XCTAssertTrue(csv.hasPrefix("id,session,message,step,at,tool"), csv.prefix(80).description)
        XCTAssertEqual(lines.count, 4, "заголовок и три строки")
    }

    func testPruneRemovesOnlyOldRows() async throws {
        try await journal.record(draft(tool: "old", args: "{}"),
                                 now: Date().addingTimeInterval(-40 * 86_400))
        try await journal.record(draft(tool: "fresh", args: "{}"))

        let removed = try await journal.prune()
        let entries = try await journal.list()

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(entries.map(\.tool), ["fresh"])
    }

    func testActivityToolListsAndExports() async throws {
        try await journal.record(draft(tool: "fs_read", args: "{}"))
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            actions: journal,
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )

        let list = await tools.activityTool(["action": "list"])
        XCTAssertFalse(list.isError, list.output)
        XCTAssertTrue(list.output.contains("fs_read"), list.output)

        let show = await tools.activityTool(["action": "show", "id": 1])
        XCTAssertTrue(show.output.contains("because: message"), show.output)
    }

    func testPruneNeedsConfirmation() async {
        let tools = ToolRegistry(
            workspace: URL(fileURLWithPath: NSTemporaryDirectory()),
            actions: journal,
            memory: nil, embeddings: nil, secrets: nil, skills: nil, mcp: nil
        )
        let result = await tools.activityTool(["action": "prune"])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("confirm"), result.output)
    }
}
