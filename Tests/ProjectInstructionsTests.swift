import XCTest
@testable import Harness

final class ProjectInstructionsTests: XCTestCase {
    private var sandbox: URL!

    override func setUp() async throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("harness-rules-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        await ProjectInstructions.shared.reset()
    }

    override func tearDown() async throws {
        if let sandbox { try? FileManager.default.removeItem(at: sandbox) }
    }

    private func write(_ name: String, _ text: String) throws {
        try text.write(to: sandbox.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func testLoadsAgentsFileFromTheWorkspace() async throws {
        try write("AGENTS.md", "Build with xcodebuild, push to origin.")

        let items = await ProjectInstructions.shared.load(workspace: sandbox)

        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].text, "Build with xcodebuild, push to origin.")
        XCTAssertTrue(items[0].path.hasSuffix("AGENTS.md"))
    }

    func testPrefersAgentsOverClaudeWhenBothExist() async throws {
        try write("AGENTS.md", "from agents")
        try write("CLAUDE.md", "from claude")

        let items = await ProjectInstructions.shared.load(workspace: sandbox)

        XCTAssertEqual(items.map(\.text), ["from agents", "from claude"])
    }

    func testLoadsCursorRulesWhenOthersAreMissing() async throws {
        try write(".cursorrules", "use tabs")

        let items = await ProjectInstructions.shared.load(workspace: sandbox)

        XCTAssertEqual(items.map(\.text), ["use tabs"])
    }

    func testCapsEachFileAndSaysSo() async throws {
        try write("AGENTS.md", String(repeating: "x", count: ProjectInstructions.perFileLimit + 5_000))

        let items = await ProjectInstructions.shared.load(workspace: sandbox)

        XCTAssertEqual(items.count, 1)
        XCTAssertLessThan(items[0].text.count, ProjectInstructions.perFileLimit + 100)
        XCTAssertTrue(items[0].text.contains("файл обрезан"))
    }

    func testCachePicksUpChanges() async throws {
        try write("AGENTS.md", "old")
        let first = await ProjectInstructions.shared.load(workspace: sandbox)
        XCTAssertEqual(first.first?.text, "old")

        // Modification dates have one-second resolution on some volumes.
        try await Task.sleep(for: .milliseconds(1_100))
        try write("AGENTS.md", "new")
        let second = await ProjectInstructions.shared.load(workspace: sandbox)
        XCTAssertEqual(second.first?.text, "new")
    }

    func testEmptyWorkspaceReturnsNothing() async {
        let items = await ProjectInstructions.shared.load(workspace: sandbox)
        XCTAssertTrue(items.isEmpty)
    }
}
