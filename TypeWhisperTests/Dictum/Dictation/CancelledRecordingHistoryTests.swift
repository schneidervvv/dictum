import XCTest
@testable import TypeWhisper

/// 按 Esc 取消后 3 秒内没有恢复：录音在后台转写并纠正，保存为已取消的历史记录，保存后才删除恢复录音。
@MainActor
final class CancelledRecordingHistoryTests: DictationSessionTestCase {
    /// 开始会话，把录音写入恢复存储，然后从语音条取消。
    private func cancelSession(_ fixture: DictationSessionFixture, mode: DictationMode = .dictation) async {
        _ = await fixture.startFromAPI(mode: mode)
        fixture.recoveryStore.append(fixture.samples)
        fixture.model.cancelFromVoiceBar()
        await fixture.model.testingWaitForRecordingCleanup()
    }

    func testWindowEndSavesOneCancelledRecordAndDeletesTheRecoveryFile() async throws {
        let fixture = try makeFixture()
        fixture.dictionary.addEntry(type: .correction, original: "clawed code", replacement: "Claude Code")
        await cancelSession(fixture)
        XCTAssertEqual(fixture.recorder.recoveryRecordingURLs.count, 1, "取消时保留恢复录音")

        try await fixture.wait(upTo: 8) {
            !fixture.history.recentRecords.isEmpty && fixture.recorder.recoveryRecordingURLs.isEmpty
        }

        XCTAssertEqual(fixture.history.recentRecords.count, 1)
        let record = try XCTUnwrap(fixture.history.recentRecords.first)
        XCTAssertTrue(record.isCancelled)
        XCTAssertEqual(record.finalText, "Claude Code is ready", "经过词典纠正，没有润色")
        XCTAssertEqual(record.mode, .dictation)
        XCTAssertEqual(record.appName, "Notes")
        XCTAssertEqual(record.appBundleIdentifier, "com.apple.Notes")
        XCTAssertNotNil(fixture.history.audioFileURL(for: record), "历史保存录音时带上录音")
        XCTAssertTrue(fixture.chain.prompts.isEmpty, "不调用 AI 模型")
        XCTAssertNil(fixture.pasteboard.string(forType: .string), "不插入")
        XCTAssertTrue(fixture.recorder.recoveryRecordingURLs.isEmpty)
    }

    func testCancelledTranslationKeepsItsModeAndPair() async throws {
        let fixture = try makeFixture()
        await cancelSession(fixture, mode: .translation)
        try await fixture.wait(upTo: 8) { !fixture.history.recentRecords.isEmpty }

        let record = try XCTUnwrap(fixture.history.recentRecords.first)
        XCTAssertTrue(record.isCancelled)
        XCTAssertEqual(record.mode, .translation)
        XCTAssertEqual(record.spokenLanguage, "en")
        XCTAssertEqual(record.targetLanguage, "ja")
        XCTAssertEqual(record.rawText, record.finalText, "还没有译文")
        XCTAssertNil(record.processingFailureMessage)
    }

    func testRestoreInsideTheWindowSavesNoCancelledRecord() async throws {
        let fixture = try makeFixture()
        fixture.chain.reply = .success("Claude Code is ready.")
        await cancelSession(fixture)
        fixture.model.restoreCancelledRecording()

        try await fixture.wait(upTo: 3) { !fixture.history.recentRecords.isEmpty }
        try await Task.sleep(for: .seconds(4))

        XCTAssertEqual(fixture.history.recentRecords.count, 1)
        XCTAssertEqual(fixture.history.recentRecords.first?.isCancelled, false)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Claude Code is ready.")
    }

    func testTranscriptionFailureKeepsTheRecoveryFile() async throws {
        let fixture = try makeFixture()
        await cancelSession(fixture)
        fixture.engine.failure = DictationSessionFixture.ProviderFailure()

        try await fixture.wait(upTo: 8) { fixture.engine.transcribeCount > 0 }
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertEqual(fixture.engine.transcribeCount, 1)
        XCTAssertTrue(fixture.history.recentRecords.isEmpty)
        XCTAssertEqual(fixture.recorder.recoveryRecordingURLs.count, 1, "恢复录音留在听写恢复里")
    }

    func testHistoryOffKeepsTheRecoveryFileAndSavesNothing() async throws {
        UserDefaults.standard.set(false, forKey: UserDefaultsKeys.historyEnabled)
        let fixture = try makeFixture()
        await cancelSession(fixture)

        try await Task.sleep(for: .seconds(4.5))

        XCTAssertEqual(fixture.engine.transcribeCount, 0, "历史关闭时不转写")
        XCTAssertTrue(fixture.history.recentRecords.isEmpty)
        XCTAssertEqual(fixture.recorder.recoveryRecordingURLs.count, 1, "恢复录音留在听写恢复里")
    }
}
