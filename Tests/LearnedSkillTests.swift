import XCTest
@testable import Harness

/// R30.4: the sanitiser and the hand-edit lock are the safety of the learned-skills loop.
final class LearnedSkillTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("learned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        LearnedSkillStore.setDirectoryOverride(directory)
    }

    override func tearDownWithError() throws {
        LearnedSkillStore.setDirectoryOverride(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    private func registry(isSubagent: Bool = false, userMessage: String? = "Сделай это",
                          secrets: SecretsService? = nil) -> ToolRegistry {
        ToolRegistry(
            workspace: directory, currentUserMessage: userMessage, isSubagent: isSubagent,
            memory: nil, embeddings: nil, secrets: secrets, skills: nil, mcp: nil
        )
    }

    func testSecretValueDoesNotReachTheFile() async throws {
        let secret = "sk-live-1234567890abcdef"
        let database = try AppDatabase(inMemory: true)
        let secrets = SecretsService(database: database)
        _ = try await secrets.save(alias: "api", value: secret)
        let result = await registry(secrets: secrets).skillLearnTool([
            "action": "save", "name": "deploy-api", "description": "Deploy the API",
            "body": "Run the deploy with token \(secret) then check health."
        ])

        XCTAssertFalse(result.isError, result.output)
        let file = try String(contentsOf: directory.appendingPathComponent("deploy-api.md"))
        XCTAssertFalse(file.contains(secret), file)
        XCTAssertTrue(file.contains("<secret>"), file)
    }

    func testCardNumberIsRefused() async {
        let result = await registry().skillLearnTool([
            "action": "save", "name": "pay", "description": "Pay",
            "body": "Use card 4111111111111111 for the order."
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("карт"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("pay.md").path))
    }

    func testKeyAssignmentIsRefused() async {
        let result = await registry().skillLearnTool([
            "action": "save", "name": "keydoc", "description": "K",
            "body": "api_key = abcdefghijklmnop"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("key"), result.output)
    }

    func testEmailAndNumbersAreMasked() async throws {
        let result = await registry().skillLearnTool([
            "action": "save", "name": "mail", "description": "Mail",
            "body": "Write to lena@example.com and mention order 123456."
        ])
        XCTAssertFalse(result.isError, result.output)
        let file = try String(contentsOf: directory.appendingPathComponent("mail.md"))
        XCTAssertTrue(file.contains("<email>"), file)
        XCTAssertTrue(file.contains("<number>"), file)
        XCTAssertFalse(file.contains("lena@example.com"), file)
    }

    func testSubagentCannotSave() async {
        let result = await registry(isSubagent: true).skillLearnTool([
            "action": "save", "name": "x", "description": "X", "body": "step"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("Сабагент"), result.output)
    }

    func testSaveWithoutAUserMessageIsRefused() async {
        let result = await registry(userMessage: nil).skillLearnTool([
            "action": "save", "name": "x", "description": "X", "body": "step"
        ])
        XCTAssertTrue(result.isError)
    }

    func testHandEditLocksPatch() async throws {
        _ = await registry().skillLearnTool([
            "action": "save", "name": "proc", "description": "Proc", "body": "one\ntwo"
        ])
        let url = directory.appendingPathComponent("proc.md")
        let edited = try String(contentsOf: url).replacingOccurrences(of: "one", with: "ONE")
        try edited.write(to: url, atomically: true, encoding: .utf8)

        let patch = await registry().skillLearnTool([
            "action": "patch", "name": "proc", "old": "two", "new": "three"
        ])

        XCTAssertTrue(patch.isError)
        XCTAssertTrue(patch.output.contains("руками"), patch.output)
    }

    func testPatchReplacesOneExactQuote() async {
        _ = await registry().skillLearnTool([
            "action": "save", "name": "proc", "description": "Proc", "body": "one\ntwo"
        ])
        let patch = await registry().skillLearnTool([
            "action": "patch", "name": "proc", "old": "two", "new": "three"
        ])

        XCTAssertFalse(patch.isError, patch.output)
        XCTAssertEqual(LearnedSkillStore.read("proc")?.body, "one\nthree")
    }

    func testBodyOverTheLimitIsRefused() async {
        let result = await registry().skillLearnTool([
            "action": "save", "name": "big", "description": "Big",
            "body": String(repeating: "a", count: 6_001)
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("6000"), result.output)
    }

    func testFiftySkillsIsTheCeiling() async {
        for index in 0..<50 {
            _ = await registry().skillLearnTool([
                "action": "save", "name": "skill-\(index)", "description": "D\(index)", "body": "b"
            ])
        }
        let result = await registry().skillLearnTool([
            "action": "save", "name": "skill-50", "description": "D", "body": "b"
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.output.contains("лимит"), result.output)
    }

    func testIndexHasNameAndDescriptionButNotTheBody() {
        _ = LearnedSkillStore.names()
        let skill = LearnedSkill(
            name: "deploy", description: "Deploy the API", created: "now", updated: "now",
            source: "chat", bodyHash: "h", body: "SECRET BODY TEXT"
        )
        try? LearnedSkillStore.save(skill)

        let index = LearnedSkillStore.list().map { "- \($0.name): \($0.description)" }
            .joined(separator: "\n")
        XCTAssertTrue(index.contains("deploy: Deploy the API"))
        XCTAssertFalse(index.contains("SECRET BODY TEXT"))
    }
}
