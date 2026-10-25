import XCTest
@testable import TypeWhisper

/// 润色或翻译失败时插入的原文仍经过词典纠正和文本片段；语音条重试把纠正后的文字发给模型，模型结果再经过纠正和文本片段。
@MainActor
final class PolishFailureCorrectionTests: DictationSessionTestCase {
    private func prepare(_ fixture: DictationSessionFixture) {
        fixture.engine.text = "clawed code is ready my sig"
        fixture.dictionary.addEntry(type: .correction, original: "clawed code", replacement: "Claude Code")
        fixture.snippets.addSnippet(trigger: "my sig", replacement: "Best, Schneider")
        fixture.chain.reply = .failure(DictationSessionFixture.ProviderFailure())
    }

    func testPolishFailureInsertsTheCorrectedOriginalWithSnippets() async throws {
        let fixture = try makeFixture()
        prepare(fixture)
        let session = await fixture.startFromAPI(mode: .dictation)
        _ = fixture.model.apiStopRecording()
        _ = try await fixture.waitUntilCompleted(session)

        let inserted = try XCTUnwrap(fixture.pasteboard.string(forType: .string))
        XCTAssertTrue(inserted.contains("Claude Code"), "插入的原文经过词典纠正：\(inserted)")
        XCTAssertTrue(inserted.contains("Best, Schneider"), "插入的原文经过文本片段：\(inserted)")
        XCTAssertFalse(inserted.contains("clawed code"))
        XCTAssertNotNil(fixture.model.polishFailure, "语音条显示润色失败并可以重试")
        XCTAssertEqual(fixture.history.recentRecords.first?.finalText, inserted)
    }

    func testTranslationFailureInsertsTheCorrectedOriginalWithSnippets() async throws {
        let fixture = try makeFixture()
        prepare(fixture)
        let session = await fixture.startFromAPI(mode: .translation)
        _ = fixture.model.apiStopRecording()
        _ = try await fixture.waitUntilCompleted(session)

        let inserted = try XCTUnwrap(fixture.pasteboard.string(forType: .string))
        XCTAssertTrue(inserted.contains("Claude Code"), "插入的原话经过词典纠正：\(inserted)")
        XCTAssertTrue(inserted.contains("Best, Schneider"), "插入的原话经过文本片段：\(inserted)")
        XCTAssertEqual(fixture.model.translationFailure, TranslationStrings.failedInserted)
    }

    func testRetrySendsTheCorrectedTextAndCorrectsTheModelResult() async throws {
        let fixture = try makeFixture()
        prepare(fixture)
        let session = await fixture.startFromAPI(mode: .dictation)
        _ = fixture.model.apiStopRecording()
        _ = try await fixture.waitUntilCompleted(session)
        XCTAssertNotNil(fixture.model.polishFailure)

        fixture.chain.reply = .success("clawed code is ready. my sig")
        fixture.model.retryPolish()
        try await fixture.wait(upTo: 3) { fixture.model.polishFailure == nil }

        XCTAssertNil(fixture.model.polishFailure)
        let retryInput = try XCTUnwrap(fixture.chain.texts.last)
        XCTAssertTrue(retryInput.contains("Claude Code"), "重试发给模型的是纠正后的文字：\(retryInput)")
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Claude Code is ready. Best, Schneider")
        fixture.model.dismissActionFeedback()
    }

    func testRetryCountsSnippetAndCorrectionUsageOncePerDictation() async throws {
        let fixture = try makeFixture()
        prepare(fixture)
        let session = await fixture.startFromAPI(mode: .dictation)
        _ = fixture.model.apiStopRecording()
        _ = try await fixture.waitUntilCompleted(session)
        let correction = try XCTUnwrap(fixture.dictionary.corrections.first)
        let snippet = try XCTUnwrap(fixture.snippets.snippets.first)
        XCTAssertEqual(correction.usageCount, 1, "插入原文时计入一次")
        XCTAssertEqual(snippet.usageCount, 1, "插入原文时计入一次")

        fixture.chain.reply = .success("clawed code is ready. my sig")
        fixture.model.retryPolish()
        try await fixture.wait(upTo: 3) { fixture.model.polishFailure == nil }

        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Claude Code is ready. Best, Schneider")
        XCTAssertEqual(correction.usageCount, 1, "同一次听写的重试没有第二次计数")
        XCTAssertEqual(snippet.usageCount, 1, "同一次听写的重试没有第二次计数")
        fixture.model.dismissActionFeedback()
    }

    /// 替换内容包含原词（Claude → Claude Code）：润色失败时插入的原文只纠正一次。
    func testCorrectionContainingItsOriginalAppliesOnceWhenPolishFails() async throws {
        let fixture = try makeFixture()
        fixture.engine.text = "Claude is ready"
        fixture.dictionary.addEntry(type: .correction, original: "Claude", replacement: "Claude Code")
        fixture.chain.reply = .failure(DictationSessionFixture.ProviderFailure())
        let session = await fixture.startFromAPI(mode: .dictation)
        _ = fixture.model.apiStopRecording()
        _ = try await fixture.waitUntilCompleted(session)

        let inserted = try XCTUnwrap(fixture.pasteboard.string(forType: .string))
        XCTAssertTrue(inserted.hasPrefix("Claude Code is ready"), "插入的原文：\(inserted)")
        XCTAssertFalse(inserted.contains("Code Code"), "插入的原文：\(inserted)")
        XCTAssertNotNil(fixture.model.polishFailure)
        XCTAssertEqual(fixture.dictionary.corrections.first?.usageCount, 1)
        XCTAssertEqual(fixture.chain.texts.last.map { $0.contains("Claude Code") }, true, "AI 步骤收到的是纠正后的文字")
    }

    /// 一条纠正的结果是另一条纠正的原词（clod → Claude，Claude → Claude Code）：润色失败时插入的原文与没有 AI 步骤的听写相同，
    /// 只经过一次纠正。
    func testPolishFailureCorrectsTheOriginalOnceLikeADictationWithoutAI() async throws {
        let fixture = try makeFixture()
        fixture.engine.text = "clod is ready"
        fixture.dictionary.addEntry(type: .correction, original: "clod", replacement: "Claude")
        fixture.dictionary.addEntry(type: .correction, original: "Claude", replacement: "Claude Code")
        fixture.chain.reply = .failure(DictationSessionFixture.ProviderFailure())
        let session = await fixture.startFromAPI(mode: .dictation)
        _ = fixture.model.apiStopRecording()
        _ = try await fixture.waitUntilCompleted(session)

        let inserted = try XCTUnwrap(fixture.pasteboard.string(forType: .string))
        XCTAssertNotNil(fixture.model.polishFailure)
        XCTAssertTrue(inserted.hasPrefix("Claude is ready"), "插入的原文只纠正一次：\(inserted)")
        XCTAssertEqual(fixture.dictionary.corrections.map(\.usageCount).sorted(), [0, 1])
    }
}
