import Markdown
import XCTest
@testable import Harness

final class StyleAnalyzerTests: XCTestCase {
    func testDetectsTyAddress() {
        let signal = StyleAnalyzer.analyze("ты проверь этот файл")
        XCTAssertEqual(signal.address, .ty)
        XCTAssertTrue(signal.isDirective)
    }

    func testDetectsVyAddress() {
        let signal = StyleAnalyzer.analyze("Вы можете проверить сборку?")
        XCTAssertEqual(signal.address, .vy)
    }

    func testDetectsSlangAndEmoji() {
        let signal = StyleAnalyzer.analyze("норм, короче 😄")
        XCTAssertTrue(signal.hasSlang)
        XCTAssertTrue(signal.hasEmoji)
    }

    func testBrevityOnShortMessage() {
        let signal = StyleAnalyzer.analyze("почини")
        XCTAssertLessThanOrEqual(signal.length, StyleAnalyzer.shortMessageChars)
    }

    func testLowLetterStartIsInformal() {
        let signal = StyleAnalyzer.analyze("надо посмотреть этот момент")
        XCTAssertTrue(signal.informalPunctuation)
    }

    func testCleanMessageIsNotInformal() {
        let signal = StyleAnalyzer.analyze("Проверь сборку проекта.")
        XCTAssertFalse(signal.informalPunctuation)
    }
}

final class StyleProfileTests: XCTestCase {
    func testTraitNeedsDaysAndObservations() {
        var profile = StyleProfile()
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        for index in 0..<12 {
            profile = StyleReducer.apply(
                profile,
                signal: StyleAnalyzer.analyze("почини баг"),
                now: now + Int64(index) * 1000,
                day: index / 6
            )
        }

        let brevity = profile.trait(.brevity)
        XCTAssertNotNil(brevity)
        XCTAssertTrue(StyleActivation.isActive(brevity!))
    }

    func testSingleEveningDoesNotActivate() {
        var profile = StyleProfile()
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for index in 0..<40 {
            profile = StyleReducer.apply(
                profile,
                signal: StyleAnalyzer.analyze("блин бля как же это бесит"),
                now: now + Int64(index) * 1000,
                day: 100
            )
        }

        let profanity = profile.trait(.profanity)
        XCTAssertNotNil(profanity)
        XCTAssertFalse(StyleActivation.isActive(profanity!), "один вечер не должен менять персону")
    }

    func testDecayReducesStaleTrait() {
        var profile = StyleProfile()
        let start = Int64(Date().timeIntervalSince1970 * 1000)
        for index in 0..<10 {
            profile = StyleReducer.apply(
                profile,
                signal: StyleAnalyzer.analyze("ок"),
                now: start,
                day: 1
            )
        }

        let before = profile.trait(.slang)?.value ?? 0
        let after = StyleReducer.decay(profile, now: start + 4 * 7 * 24 * 3600 * 1000)
            .trait(.slang)?.value ?? 0
        XCTAssertLessThan(after, before)
    }

    func testBlockRenderingRespectsModeAndCap() {
        var profile = StyleProfile()
        profile.traits = [
            StyleTrait(key: .address, value: 0.9, observations: 20, hitMessages: 18, dayKeys: [1, 2]),
            StyleTrait(key: .brevity, value: 0.8, observations: 20, hitMessages: 16, dayKeys: [1, 2])
        ]

        let auto = StyleBlockBuilder.render(profile)
        XCTAssertTrue(auto.contains("«ты»"))
        XCTAssertFalse(auto.contains("коротко"), "краткость задаётся температурой, а не промптом")
        XCTAssertLessThanOrEqual(auto.count, StyleBlockBuilder.maxBlockChars)

        var neutral = profile
        neutral.mode = .neutral
        XCTAssertEqual(StyleBlockBuilder.render(neutral), "")
    }

    func testManualCardIsUsedVerbatim() {
        var profile = StyleProfile(mode: .manual, manualCard: "пиши по-дружески")
        XCTAssertTrue(StyleBlockBuilder.render(profile).contains("пиши по-дружески"))

        profile.manualCard = "пиши как пидор"
        XCTAssertEqual(StyleBlockBuilder.render(profile), "", "жёсткая лексика не попадает в промпт")
    }

    func testProfanityLexiconSeparatesMildFromInsult() {
        let mild = ProfanityLexicon.scan("блин, опять бля")
        XCTAssertTrue(mild.mild)
        XCTAssertFalse(mild.isHostile)

        let insult = ProfanityLexicon.scan("ты идиот")
        XCTAssertTrue(insult.insult)
        XCTAssertTrue(insult.isHostile)
    }

    func testPromptBlockIsFrozenButExplicitChangesApply() async throws {
        let database = try AppDatabase()
        let store = StyleStore(database: database)
        await store.setMode(.auto)

        let first = await store.promptBlock(refreshEvery: 5)

        // Automatic learning must not shift the block mid-cycle: it sits in the cached
        // prompt prefix, and every shift costs a full re-prefill.
        await store.observe("привет, братан, как дела")
        let second = await store.promptBlock(refreshEvery: 5)
        XCTAssertEqual(second, first)

        // An explicit change is different: the user expects it at once.
        await store.setMode(.manual)
        await store.setManualCard("Коротко и по делу")
        let third = await store.promptBlock(refreshEvery: 5)
        XCTAssertTrue(third.contains("Коротко и по делу"))
    }

    func testStoreObservesAndPersists() async throws {
        let database = try AppDatabase()
        let store = StyleStore(database: database)

        let initial = await store.current()
        XCTAssertEqual(initial.samples, 0)

        await store.observe("почини сборку")
        let updated = await store.current()
        XCTAssertEqual(updated.samples, 1)

        await store.setMode(.manual)
        let mode = await store.current().mode
        XCTAssertEqual(mode, .manual)
    }

    func testCardNormalization() {
        XCTAssertEqual(StyleCardExtractor.normalizeCard("\"коротко, на ты\""), "коротко, на ты")
        XCTAssertEqual(StyleCardExtractor.normalizeCard("- коротко, с иронией"), "коротко, с иронией")
        XCTAssertEqual(StyleCardExtractor.normalizeCard(""), "")
        XCTAssertEqual(StyleCardExtractor.normalizeCard("пиши как пидор"), "")
    }

    func testTranscriptNeedsEnoughSamples() {
        XCTAssertNil(StyleCardExtractor.transcript(from: ["раз", "два"]))
        let many = (0..<25).map { "сообщение \($0)" }
        XCTAssertNotNil(StyleCardExtractor.transcript(from: many))
    }
}

final class MarkdownMetricsTests: XCTestCase {
    @MainActor
    func testHeadingLadderIsFlatAndAbsolute() {
        // At a 14 pt body this is 17 / 15 / 14 — the same ladder the reference UI uses.
        XCTAssertEqual(MarkdownBlockView.headingSize(level: 1, fontSize: 14), 17)
        XCTAssertEqual(MarkdownBlockView.headingSize(level: 2, fontSize: 14), 15)
        XCTAssertEqual(MarkdownBlockView.headingSize(level: 3, fontSize: 14), 14)
        XCTAssertEqual(MarkdownBlockView.headingSize(level: 6, fontSize: 14), 14)
    }

    @MainActor
    func testHeadingStepDoesNotGrowWithFontSize() {
        for size in [11.0, 14.0, 20.0] as [CGFloat] {
            XCTAssertEqual(MarkdownBlockView.headingSize(level: 1, fontSize: size) - size, 3, accuracy: 0.001)
        }
    }

    @MainActor
    func testHeadingWeights() {
        XCTAssertEqual(MarkdownBlockView.headingWeight(level: 1), .semibold)
        XCTAssertEqual(MarkdownBlockView.headingWeight(level: 3), .semibold)
        XCTAssertEqual(MarkdownBlockView.headingWeight(level: 4), .regular)
    }

    @MainActor
    func testLineBoxIsAboutOneFiftyTwoPercent() {
        // Leading was tightened from 0.28 em to 0.20 em of extra space: the block sits
        // at ~1.52 of the body size instead of 1.6. Paragraph gaps carry the rest.
        for size in [11.0, 14.0, 20.0] as [CGFloat] {
            let total = size * 1.32 + AppFont.lineSpacing(for: size)
            XCTAssertEqual(total / size, 1.52, accuracy: 0.04, "size \(size)")
        }
    }

    @MainActor
    func testBlockRhythm() throws {
        let markdown = """
        # Title

        Some paragraph.

        - one
        - two

        > quote

        ```swift
        let x = 1
        ```

        | a | b |
        |---|---|
        | 1 | 2 |
        """
        let document = Document(parsing: markdown)
        let blocks = Array(document.children)

        // Paragraphs are 20 apart — a visible blank line now that leading is tighter.
        // Code gets 24 below, headings 28 above and 12 below.
        XCTAssertEqual(MarkdownBlockView.marginBottom(blocks[1]), 20)
        XCTAssertEqual(MarkdownBlockView.marginTop(blocks[2]), 8)
        XCTAssertEqual(MarkdownBlockView.marginTop(blocks[3]), 16)
        XCTAssertEqual(MarkdownBlockView.marginBottom(blocks[4]), 24)

        // Collapse: the larger of the two adjacent margins wins, they never sum.
        XCTAssertEqual(
            MarkdownBlockView.gap(after: blocks[1], before: blocks[2]),
            max(MarkdownBlockView.marginBottom(blocks[1]), MarkdownBlockView.marginTop(blocks[2]))
        )
        XCTAssertEqual(MarkdownBlockView.gap(after: blocks[2], before: blocks[3]), 16)
    }
}
