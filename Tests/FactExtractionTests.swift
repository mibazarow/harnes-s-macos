import XCTest
@testable import Harness

/// R31.3: facts are pulled from the user's words before the messages are folded, and a
/// fact whose quote is not in the source never reaches memory.
final class FactExtractionTests: XCTestCase {
    func testParseReadsTheJsonArray() {
        let raw = """
        Вот результат:
        [{"content":"Сервер на Ubuntu 24.04","quote":"сервер на убунту 24.04","area":"fact"},
         {"content":"Любит короткие ответы","quote":"пиши коротко","area":"preferences"}]
        """
        let parsed = FactExtraction.parse(raw)
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].area, "fact")
        XCTAssertEqual(parsed[1].area, "preferences")
    }

    func testParseRejectsBrokenJson() {
        XCTAssertTrue(FactExtraction.parse("не json").isEmpty)
        XCTAssertTrue(FactExtraction.parse("[]").isEmpty)
        XCTAssertTrue(FactExtraction.parse(#"[{"content":"без цитаты"}]"#).isEmpty)
    }

    func testUnknownAreaFallsBackToFact() {
        let parsed = FactExtraction.parse(
            #"[{"content":"Факт","quote":"факт","area":"nonsense"}]"#
        )
        XCTAssertEqual(parsed.first?.area, "fact")
    }

    func testHallucinatedQuoteIsDropped() {
        let candidates = [
            FactExtraction.Candidate(content: "Живёт в Москве", quote: "я живу в москве", area: "fact"),
            FactExtraction.Candidate(content: "Любит кофе", quote: "я обожаю кофе", area: "fact")
        ]
        let kept = FactExtraction.verified(candidates, against: ["Я живу в Москве, работаю удалённо."])
        XCTAssertEqual(kept.map(\.content), ["Живёт в Москве"])
    }

    func testDuplicatesCollapse() {
        let candidates = [
            FactExtraction.Candidate(content: "Сервер на Ubuntu", quote: "сервер на убунту", area: "fact"),
            FactExtraction.Candidate(content: "сервер на ubuntu", quote: "сервер на убунту", area: "fact")
        ]
        let kept = FactExtraction.verified(candidates, against: ["сервер на убунту"])
        XCTAssertEqual(kept.count, 1)
    }

    func testCapIsRespected() {
        let source = (0..<20).map { "факт номер \($0)" }.joined(separator: ". ")
        let candidates = (0..<20).map { index in
            FactExtraction.Candidate(
                content: "Факт \(index)", quote: "факт номер \(index)", area: "fact"
            )
        }
        let kept = FactExtraction.verified(candidates, against: [source])
        XCTAssertEqual(kept.count, FactExtraction.maxCandidates)
    }

    func testOnlyUserMessagesAreRead() {
        let messages = [
            ContextMessage(id: 0, role: "system", text: "ты ассистент, и это не слова пользователя"),
            ContextMessage(id: 1, role: "assistant", text: "я думаю, пользователь живёт в Москве"),
            ContextMessage(id: 2, role: "user", text: "я живу в Москве")
        ]
        XCTAssertEqual(FactExtraction.userText(from: messages), ["я живу в Москве"])
    }

    func testKindFollowsArea() {
        XCTAssertEqual(FactExtraction.kind(for: "preferences"), "preference")
        XCTAssertEqual(FactExtraction.kind(for: "lessons"), "lesson")
        XCTAssertEqual(FactExtraction.kind(for: "fact"), "fact")
        XCTAssertEqual(FactExtraction.kind(for: "people"), "person")
    }

    func testExtractionEndToEndSavesVerifiedFacts() async throws {
        let server = try StubSSEServer(chunks: [
            #"{"choices":[{"delta":{"content":"[{\"content\":\"Сервер на Ubuntu\",\"quote\":\"сервер на убунту\",\"area\":\"fact\"}]"}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#
        ])
        try server.start()
        defer { server.stop() }

        let provider = ProviderModel(
            id: "p", name: "stub", baseURL: server.baseURL, apiKey: "k",
            models: ["m"], defaultModel: "m", contextWindow: 128_000, isDefault: true
        )
        let candidates = try await FactExtractor().extract(
            messages: [ContextMessage(id: 0, role: "user", text: "сервер на убунту, запомни")],
            provider: provider,
            model: "m"
        )
        XCTAssertEqual(candidates.map(\.content), ["Сервер на Ubuntu"])
    }
}
