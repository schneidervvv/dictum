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
}
