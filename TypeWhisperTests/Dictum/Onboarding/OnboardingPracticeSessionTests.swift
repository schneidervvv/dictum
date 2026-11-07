import XCTest
@testable import TypeWhisper

/// 离开练习步骤时，仍在录音或识别的练习会话按用户取消处理：不向任何窗口插入文字。
@MainActor
final class OnboardingPracticeSessionTests: DictationSessionTestCase {
    private let longRecording = Array(repeating: Float(0.25), count: 3 * Int(AudioRecordingService.targetSampleRate))

    func testEndingWhileRecordingCancelsTheSessionAndInsertsNothing() async throws {
        let fixture = try makeFixture()
        _ = await fixture.startFromAPI(mode: .dictation)
        XCTAssertEqual(fixture.model.state, .recording)

        OnboardingPracticeSession.end(fixture.model)
        await fixture.model.testingWaitForRecordingCleanup()

        XCTAssertNotEqual(fixture.model.state, .recording)
        XCTAssertNotNil(fixture.model.cancelledRecordingDeadline, "录音按取消保留恢复窗口")
        XCTAssertEqual(fixture.engine.transcribeCount, 0)
        XCTAssertNil(fixture.pasteboard.string(forType: .string))
    }

    func testEndingWhileProcessingStopsTheTranscriptionAndInsertsNothing() async throws {
        let fixture = try makeFixture()
        fixture.engine.holdsLongRecordings = true
        fixture.recorded.samples = longRecording
        _ = await fixture.startFromAPI(mode: .dictation)
        _ = fixture.model.apiStopRecording()
        try await fixture.wait(upTo: 3) { fixture.engine.transcribeCount == 1 }
        XCTAssertEqual(fixture.model.state, .processing)

        OnboardingPracticeSession.end(fixture.model)
        fixture.engine.holdsLongRecordings = false
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertNotEqual(fixture.model.state, .processing)
        XCTAssertNil(fixture.pasteboard.string(forType: .string), "取消后识别结果没有插入")
    }

    func testEndingWhileIdleLeavesTheModelAlone() throws {
        let fixture = try makeFixture()

        OnboardingPracticeSession.end(fixture.model)

        XCTAssertEqual(fixture.model.state, .idle)
        XCTAssertNil(fixture.model.cancelledRecordingDeadline)
    }

    func testOnlyThePracticeStepsArePractice() {
        XCTAssertEqual(
            (0..<OnboardingStep.count).filter(OnboardingStep.isPractice),
            [OnboardingStep.dictationPractice, OnboardingStep.translationPractice])
    }
}
