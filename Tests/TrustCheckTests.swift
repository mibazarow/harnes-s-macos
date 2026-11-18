import XCTest
@testable import Harness

/// R30.7: the checker picks a source, the server verifies the quote, and nothing runs
/// without a verbatim fragment of the user's own words.
final class TrustCheckTests: XCTestCase {
    private actor StubAsker: TrustAsking {
        private let answer: TrustAnswer?
        private let shouldThrow: Bool
        private var seen = 0

        init(_ answer: TrustAnswer?, throws shouldThrow: Bool = false) {
            self.answer = answer
            self.shouldThrow = shouldThrow
        }

        func ask(_ request: TrustCheckRequest) async throws -> TrustAnswer? {
            seen += 1
            if shouldThrow { throw NSError(domain: "stub", code: 1) }
            return answer
        }

        func calls() -> Int { seen }
    }

    private let candidates = [
        TrustCandidate(id: "current", text: "Почини кэш на сервере, он разросся."),
        TrustCandidate(id: "m1", text: "Посмотри, что там с кэшем.")
    ]

    private func call(_ tool: String, _ json: String) -> ToolCall {
        ToolCall(id: "1", name: tool, arguments: json)
    }

    private var context: ToolCallContext {
        ToolCallContext(workspace: URL(fileURLWithPath: "/tmp/work"), readOnly: false)
    }

    private func interceptor(
        _ answer: TrustAnswer?, autopilot: Bool = false,
        session: TrustCheckSession = TrustCheckSession()
    ) -> TrustCheckInterceptor {
        session.beginTurn()
        return TrustCheckInterceptor(
            session: session, candidates: candidates, instructions: [],
            autopilot: autopilot, asker: StubAsker(answer)
        )
    }

    // MARK: - Policy

    func testPolicySeparatesQuoteFromStandard() {
        let workspace = URL(fileURLWithPath: "/tmp/work")
        XCTAssertEqual(
            TrustPolicy.requirement(tool: "memory_add", args: [:], workspace: workspace), .quote
        )
        XCTAssertEqual(
            TrustPolicy.requirement(tool: "secret_save", args: [:], workspace: workspace), .quote
        )
        XCTAssertEqual(
            TrustPolicy.requirement(
                tool: "secret_get", args: ["reveal": true], workspace: workspace
            ), .quote
        )
        XCTAssertNil(
            TrustPolicy.requirement(
                tool: "secret_get", args: ["reveal": false], workspace: workspace
            )
        )
        XCTAssertEqual(
            TrustPolicy.requirement(
                tool: "bash", args: ["command": "sudo launchctl kickstart x"], workspace: workspace
            ), .quote
        )
        XCTAssertNil(
            TrustPolicy.requirement(
                tool: "bash", args: ["command": "ls -la"], workspace: workspace
            )
        )
        XCTAssertEqual(
            TrustPolicy.requirement(
                tool: "power", args: ["action": "sleep"], workspace: workspace
            ), .standard
        )
        XCTAssertNil(
            TrustPolicy.requirement(
                tool: "power", args: ["action": "status"], workspace: workspace
            )
        )
        XCTAssertNil(
            TrustPolicy.requirement(
                tool: "ui", args: ["action": "click"], workspace: workspace
            ),
            "клики в приложении, которое назвал пользователь, — это работа, а не побочный эффект"
        )
    }

    func testWritesInsideTheWorkspaceNeedNoCheck() {
        let workspace = URL(fileURLWithPath: "/tmp/work")
        XCTAssertNil(
            TrustPolicy.requirement(
                tool: "fs_write", args: ["path": "notes.md"], workspace: workspace
            )
        )
        XCTAssertEqual(
            TrustPolicy.requirement(
                tool: "fs_write", args: ["path": "/etc/hosts"], workspace: workspace
            ), .quote
        )
        XCTAssertEqual(
            TrustPolicy.requirement(
                tool: "edit_file", args: ["path": "../other/file.swift"], workspace: workspace
            ), .quote
        )
    }

    // MARK: - Normalisation

    func testPlainMatchesQuotesAndSpacing() {
        XCTAssertEqual(
            TrustCheck.plain("Он сказал  «привет»   и ушёл"),
            TrustCheck.plain("он сказал \"привет\" и ушёл")
        )
        XCTAssertTrue(TrustCheck.verify(quote: "почини кэш", in: candidates[0].text))
        XCTAssertTrue(TrustCheck.verify(quote: "ПОЧИНИ   КЭШ", in: candidates[0].text))
        XCTAssertFalse(TrustCheck.verify(quote: "удали кэш", in: candidates[0].text))
    }

    // MARK: - Gate

    func testCoveredActionIsAllowedWithTheQuote() async throws {
        let session = TrustCheckSession()
        let gate = interceptor(
            .yes(sourceID: "current", quote: "Почини кэш на сервере"), session: session
        )

        let verdict = try await gate.beforeCall(
            call("power", #"{"action":"sleep"}"#), context: context
        )

        XCTAssertEqual(verdict, .allow)
        let decision = session.decision(tool: "power")
        XCTAssertEqual(decision?.basis, .message)
        XCTAssertEqual(decision?.quote, "Почини кэш на сервере")
    }

    func testHallucinatedQuoteIsRefused() async throws {
        let gate = interceptor(.yes(sourceID: "current", quote: "Удали все логи"))

        guard case .deny(let reason, _) = try await gate.beforeCall(
            call("power", #"{"action":"sleep"}"#), context: context
        ) else {
            return XCTFail("выдуманная цитата должна быть отказом")
        }
        XCTAssertTrue(reason.contains("цитата не найдена"), reason)
    }

    func testMissingSourceIsSearchedOnTheServer() async throws {
        let session = TrustCheckSession()
        let gate = interceptor(
            .yes(sourceID: nil, quote: "что там с кэшем"), session: session
        )

        let verdict = try await gate.beforeCall(
            call("power", #"{"action":"sleep"}"#), context: context
        )

        XCTAssertEqual(verdict, .allow)
        XCTAssertEqual(session.decision(tool: "power")?.basis, .rule)
    }

    func testNoAndConditionalAreRefused() async throws {
        for answer in [TrustAnswer.no, TrustAnswer.other] {
            let gate = interceptor(answer)
            guard case .deny(let reason, _) = try await gate.beforeCall(
                call("power", #"{"action":"sleep"}"#), context: context
            ) else {
                return XCTFail("\(answer) должен быть отказом")
            }
            XCTAssertTrue(reason.contains("не покрыто"), reason)
        }
    }

    func testConfirmTurnsARefusalIntoAnApproval() async throws {
        let gate = interceptor(.no)

        let verdict = try await gate.beforeCall(
            call("power", #"{"action":"sleep","confirm":true}"#), context: context
        )

        XCTAssertEqual(verdict, .allow)
    }

    func testAutopilotKeepsCheckingAndRecordsItsOwnBasis() async throws {
        let session = TrustCheckSession()
        let gate = interceptor(
            .yes(sourceID: "current", quote: "Почини кэш"), autopilot: true, session: session
        )

        _ = try await gate.beforeCall(call("power", #"{"action":"sleep"}"#), context: context)

        XCTAssertEqual(session.decision(tool: "power")?.basis, .autopilot)
    }

    func testSecondCallOfTheSameActionDoesNotAskAgain() async throws {
        let asker = StubAsker(.yes(sourceID: "current", quote: "Почини кэш"))
        let session = TrustCheckSession()
        session.beginTurn()
        let gate = TrustCheckInterceptor(
            session: session, candidates: candidates, instructions: [],
            autopilot: false, asker: asker
        )

        _ = try await gate.beforeCall(call("power", #"{"action":"sleep"}"#), context: context)
        _ = try await gate.beforeCall(call("power", #"{"action":"sleep"}"#), context: context)

        let calls = await asker.calls()
        XCTAssertEqual(calls, 1, "одна проверка на действие за ход")
    }

    func testTwentyCallsPerTurnThenEscalation() async throws {
        let session = TrustCheckSession()
        session.beginTurn()
        let gate = TrustCheckInterceptor(
            session: session, candidates: candidates, instructions: [],
            autopilot: false,
            asker: StubAsker(.yes(sourceID: "current", quote: "Почини кэш"))
        )

        let calls = [
            call("power", #"{"action":"sleep"}"#),
            call("display", #"{"action":"set_mode","display":0,"width":1,"height":1}"#),
            call("calendar", #"{"action":"create_event","title":"x"}"#),
            call("contacts", #"{"action":"create"}"#),
            call("share", #"{"action":"send","to":["a@b"]}"#),
            call("launchd", #"{"action":"tm_start"}"#),
            call("process", #"{"action":"run","command":"x"}"#),
            call("apps", #"{"action":"quit"}"#),
            call("observe", #"{"action":"replay","path":"m.json"}"#),
            call("skill_learn", #"{"action":"save","name":"x"}"#),
            call("git", #"{"action":"push"}"#),
            call("network", #"{"action":"proxy","value":true}"#),
            call("files", #"{"action":"eject"}"#),
            call("secret_save", #"{"alias":"a"}"#),
            call("memory_add", #"{"text":"x"}"#),
            call("schedule_add", #"{"cron":"* * * * *"}"#),
            call("schedule_remove", #"{"id":1}"#),
            call("workspace", #"{"action":"set","path":"/tmp"}"#),
            call("settings", #"{"action":"appearance","value":"dark"}"#),
            call("fs_write", #"{"path":"/etc/hosts","content":"x"}"#)
        ]
        for (index, item) in calls.enumerated() {
            let verdict = try await gate.beforeCall(item, context: context)
            XCTAssertEqual(verdict, .allow, "проверка \(index + 1)")
        }
        XCTAssertEqual(session.callsUsed(), 20)
        XCTAssertEqual(
            session.reserve(tool: "power"), .reuse(session.decision(tool: "power")!)
        )
        XCTAssertEqual(session.reserve(tool: "notify"), .exhausted)
    }

    func testBrokenCheckerFailsClosed() async throws {
        let session = TrustCheckSession()
        session.beginTurn()
        let gate = TrustCheckInterceptor(
            session: session, candidates: candidates, instructions: [],
            autopilot: false, asker: StubAsker(nil, throws: true)
        )

        do {
            _ = try await gate.beforeCall(call("power", #"{"action":"sleep"}"#), context: context)
            XCTFail("исключение чекера должно доходить до цепочки и превращаться в отказ")
        } catch {
            XCTAssertNotNil(error)
        }
    }

    // MARK: - Parsing

    func testParserAcceptsJSONInsideProse() {
        let raw = #"Вот ответ: {"decision":"yes","source_id":"current","quote":"почини кэш"} — всё."#
        XCTAssertEqual(
            TrustModelAsker.parse(raw),
            .yes(sourceID: "current", quote: "почини кэш")
        )
    }

    func testParserTreatsYesWithoutQuoteAsOther() {
        XCTAssertEqual(TrustModelAsker.parse(#"{"decision":"yes"}"#), .other)
    }

    func testParserTreatsGarbageAsOtherAndEmptyAsNil() {
        XCTAssertEqual(TrustModelAsker.parse("не знаю"), .other)
        XCTAssertNil(TrustModelAsker.parse("   "))
    }

    @MainActor
    func testCandidatesKeepOnlyUserWords() {
        let messages = [
            ChatMessage(role: .user, text: "Сделай сборку"),
            ChatMessage(role: .assistant, text: "Сделал"),
            ChatMessage(role: .user, text: "Теперь запуши"),
            ChatMessage(role: .user, text: "Теперь запуши")
        ]

        let built = ChatStore.trustCandidates(current: "Теперь запуши", messages: messages)

        XCTAssertEqual(built.first?.id, "current")
        XCTAssertEqual(built.first?.text, "Теперь запуши")
        XCTAssertTrue(built.allSatisfy { $0.text != "Сделал" })
        XCTAssertEqual(built.count, 2, "текущее сообщение не дублируется как раннее")
    }
}
