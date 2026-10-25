import XCTest
@testable import TypeWhisper

/// 按 Esc 取消后 3 秒内没有恢复：录音在后台转写并纠正，保存为已取消的历史记录，保存后才删除恢复录音。
@MainActor
final class CancelledRecordingHistoryTests: DictationSessionTestCase {
    /// 开始会话，把录音写入恢复存储，然后从语音条取消。
    private func cancelSession(
        _ fixture: DictationSessionFixture, mode: DictationMode = .dictation, recording: [Float]? = nil
    ) async {
        let recording = recording ?? fixture.samples
        fixture.recorded.samples = recording
        _ = await fixture.startFromAPI(mode: mode)
        fixture.recoveryStore.append(recording)
        fixture.model.cancelFromVoiceBar()
        await fixture.model.testingWaitForRecordingCleanup()
        fixture.recorded.samples = fixture.samples
    }

    /// 3 秒的录音；`holdsLongRecordings` 打开时，它的识别一直占着识别门。
    private let longRecording = Array(repeating: Float(0.25), count: 3 * Int(AudioRecordingService.targetSampleRate))

    /// 按开始识别的顺序，每次识别的是不是长录音（已取消的那段）。
    private func longRecordingOrder(_ fixture: DictationSessionFixture) -> [Bool] {
        fixture.engine.transcribedSampleCounts.map { $0 > DictationSessionFixture.Engine.longRecordingSampleCount }
    }

    private func cancelledRecords(_ fixture: DictationSessionFixture) -> [TranscriptionRecord] {
        fixture.history.recentRecords.filter(\.isCancelled)
    }

    private func pressFn(_ fixture: DictationSessionFixture) throws {
        try fixture.flagsChanged(DictationSessionFixture.fnKey, down: true, flags: .maskSecondaryFn)
        try fixture.flagsChanged(DictationSessionFixture.fnKey, down: false, flags: [])
    }

    /// 在撤销窗口里按 Fn 开始新的听写，录音开始后再按 Fn 结束它。
    private func dictateWithFnRightAfterCancel(_ fixture: DictationSessionFixture) async throws {
        try pressFn(fixture)
        try await fixture.wait(upTo: 2) { fixture.model.state == .recording }
        XCTAssertEqual(fixture.model.state, .recording, "Fn 开始了新的听写")
        await fixture.model.testingWaitForRecordingStart()
        // 两次轻按间隔超过快捷键服务的双击判定（0.4 秒）。
        try await Task.sleep(for: .milliseconds(500))
        try pressFn(fixture)
    }

    /// 取消后立即按 Fn 开始新的听写：取消窗口随即结束，新的听写先识别，已取消的录音等它插入后才转写。
    func testDictationStartedRightAfterCancelIsNotQueuedBehindTheCancelledRecording() async throws {
        let fixture = try makeFixture()
        fixture.engine.holdsLongRecordings = true
        await cancelSession(fixture, recording: longRecording)
        fixture.engine.text = "next dictation"
        fixture.chain.reply = .success("Next dictation.")

        try await dictateWithFnRightAfterCancel(fixture)
        try await fixture.wait(upTo: 4) { fixture.pasteboard.string(forType: .string) == "Next dictation." }

        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Next dictation.", "新的听写没有等已取消录音的识别")
        try await fixture.wait(upTo: 3) { fixture.engine.transcribeCount == 2 }
        XCTAssertEqual(longRecordingOrder(fixture), [false, true], "已取消的录音在新的听写之后转写")
        XCTAssertTrue(cancelledRecords(fixture).isEmpty)

        fixture.engine.holdsLongRecordings = false
        try await fixture.wait(upTo: 3) { !self.cancelledRecords(fixture).isEmpty }
        XCTAssertEqual(cancelledRecords(fixture).map(\.finalText), ["next dictation"])
        XCTAssertEqual(fixture.history.recentRecords.count, 2)
        XCTAssertTrue(fixture.recorder.recoveryRecordingURLs.isEmpty)
        XCTAssertEqual(fixture.engine.transcribeCount, 2)
    }

    /// 后台转写进行中开始新的听写：转写让出识别引擎，新的听写插入后重新转写，只保存一条已取消的记录。
    func testDictationStartedDuringTheBackgroundTranscriptionStopsItAndItRunsAgainAfterward() async throws {
        let fixture = try makeFixture()
        fixture.engine.holdsLongRecordings = true
        await cancelSession(fixture, recording: longRecording)
        try await fixture.wait(upTo: 8) { fixture.engine.transcribeCount == 1 }
        XCTAssertEqual(longRecordingOrder(fixture), [true], "取消窗口结束后开始后台转写")

        fixture.chain.reply = .success("Next dictation.")
        let session = await fixture.startFromAPI(mode: .dictation)
        _ = fixture.model.apiStopRecording()
        let snapshot = try await fixture.waitUntilCompleted(session)

        XCTAssertEqual(snapshot?.status, .completed, "新的听写没有等后台转写")
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Next dictation.")
        XCTAssertEqual(fixture.recorder.recoveryRecordingURLs.count, 1, "转写取消时恢复录音还在")
        try await fixture.wait(upTo: 3) { fixture.engine.transcribeCount == 3 }
        XCTAssertEqual(longRecordingOrder(fixture), [true, false, true], "新的听写结束后重新转写")

        fixture.engine.holdsLongRecordings = false
        try await fixture.wait(upTo: 3) { !self.cancelledRecords(fixture).isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(cancelledRecords(fixture).count, 1)
        XCTAssertEqual(fixture.history.recentRecords.count, 2)
        XCTAssertTrue(fixture.recorder.recoveryRecordingURLs.isEmpty)
        XCTAssertEqual(fixture.engine.transcribeCount, 3)
    }

    /// 后台转写占用识别引擎时开始历史重试：重试不被忙碌拒绝，后台转写让位，重试结束后重新转写，只保存一条已取消的记录。
    func testHistoryRetranscriptionDuringTheBackgroundTranscriptionIsNotRefusedAndTheSaveRunsAfterward() async throws {
        let fixture = try makeFixture()
        fixture.engine.holdsLongRecordings = true
        await cancelSession(fixture, recording: longRecording)
        try await fixture.wait(upTo: 8) { fixture.engine.transcribeCount == 1 }
        XCTAssertEqual(longRecordingOrder(fixture), [true], "取消窗口结束后开始后台转写")

        // 历史里一条带录音的记录作为重试对象。
        let recordID = UUID()
        let audioName = await fixture.history.writeAudioFileInBackground(fixture.samples, forRecordID: recordID)
        XCTAssertTrue(fixture.history.addRecord(
            id: recordID, rawText: "earlier dictation", finalText: "earlier dictation",
            appName: "Notes", appBundleIdentifier: "com.apple.Notes", durationSeconds: 1,
            language: "en", engineUsed: fixture.engine.providerId, modelUsed: "Tiny", audioFileName: audioName
        ))
        let record = try XCTUnwrap(fixture.history.record(withID: recordID))

        let watchFolder = WatchFolderService(
            audioFileService: AudioFileService(), modelManagerService: fixture.modelManager,
            appSupportDirectory: directory, audioSamplesLoader: { _ in fixture.samples }
        )
        let service = HistoryRetranscriptionService(
            history: fixture.history,
            planBuilder: { request in
                try HistoryRetranscriptionEnvironment.plan(
                    request, manager: fixture.modelManager, dictionary: fixture.dictionary,
                    workflows: [], promptProcessing: fixture.promptProcessing
                )
            },
            isBusy: {
                HistoryRetranscriptionEnvironment.isBackgroundTranscriptionBusy(
                    manager: fixture.modelManager, watchFolder: watchFolder)
            },
            loadAudio: { _ in fixture.samples }
        )
        defer { service.cancel() }
        service.start(
            record: record, request: .init(engineID: fixture.engine.providerId),
            cloudConfirmed: true, downloadConfirmed: true
        )

        XCTAssertNil(service.errorMessage, "历史重试没有被忙碌拒绝")
        XCTAssertEqual(service.runningRecordID, record.id)

        try await fixture.wait(upTo: 8) { service.runningRecordID == nil }
        XCTAssertNil(service.errorMessage)
        XCTAssertEqual(try record.savedTranscriptionVersions().count, 2, "重试完成了识别并保存了结果")

        try await fixture.wait(upTo: 4) { fixture.engine.transcribeCount == 3 }
        fixture.engine.holdsLongRecordings = false
        try await fixture.wait(upTo: 4) { !self.cancelledRecords(fixture).isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(cancelledRecords(fixture).count, 1, "让位后重新转写只保存一条已取消的记录")
        XCTAssertEqual(fixture.history.recentRecords.count, 2)
        XCTAssertTrue(fixture.recorder.recoveryRecordingURLs.isEmpty)
    }

    /// 推迟的后台转写进行中退出应用：识别门关闭，转写停止，恢复录音留在听写恢复里，没有反复重试。
    func testQuitDuringTheDeferredBackgroundTranscriptionKeepsTheRecoveryFile() async throws {
        let fixture = try makeFixture()
        fixture.engine.holdsLongRecordings = true
        await cancelSession(fixture, recording: longRecording)
        fixture.chain.reply = .success("Next dictation.")
        try await dictateWithFnRightAfterCancel(fixture)
        try await fixture.wait(upTo: 4) { fixture.engine.transcribeCount == 2 }
        XCTAssertEqual(longRecordingOrder(fixture), [false, true])

        var replied = false
        _ = TerminationPreparation(gate: fixture.engine.localInferenceGate).requestTermination { replied = true }
        try await fixture.wait(upTo: 3) { replied }
        XCTAssertTrue(replied, "退出等到识别停止后回复")
        try await Task.sleep(for: .milliseconds(500))

        XCTAssertTrue(cancelledRecords(fixture).isEmpty)
        XCTAssertEqual(fixture.recorder.recoveryRecordingURLs.count, 1, "恢复录音留在听写恢复里")
        XCTAssertEqual(fixture.engine.transcribeCount, 2)
    }

    private func makeRecoveryViewModel(
        _ fixture: DictationSessionFixture, transcribe: @escaping @MainActor () async -> String
    ) throws -> DictationRecoveryViewModel {
        let suite = "dictum-recovery-claim-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return DictationRecoveryViewModel(
            audioRecordingService: fixture.recorder,
            modelManager: ModelManagerService(),
            historyService: fixture.history,
            audioFileService: AudioFileService(),
            defaults: try XCTUnwrap(UserDefaults(suiteName: suite)),
            transcriptionRunner: { samples, _, _, _, _ in
                TranscriptionResult(
                    text: await transcribe(), detectedLanguage: "en",
                    duration: Double(samples.count) / AudioRecordingService.targetSampleRate,
                    processingTime: 0.1, engineUsed: "session-test-engine", segments: []
                )
            },
            engineReadinessChecker: { _ in true }
        )
    }

    /// 后台转写进行中从听写恢复恢复同一段录音：恢复先保存，后台转写放弃结果，只有一条记录。
    func testRestoreFromDictationRecoveryDuringTheBackgroundTranscriptionSavesTheRecordingOnce() async throws {
        let fixture = try makeFixture()
        fixture.engine.holdsLongRecordings = true
        await cancelSession(fixture, recording: longRecording)
        try await fixture.wait(upTo: 8) { fixture.engine.transcribeCount == 1 }

        let recovery = try makeRecoveryViewModel(fixture) { "Restored recording" }
        XCTAssertNotNil(recovery.selectedRecovery)
        recovery.transcribe()
        try await fixture.wait(upTo: 3) { !fixture.history.recentRecords.isEmpty }
        fixture.engine.holdsLongRecordings = false
        try await Task.sleep(for: .seconds(1))

        XCTAssertEqual(fixture.history.recentRecords.map(\.finalText), ["Restored recording"])
        XCTAssertEqual(fixture.history.recentRecords.first?.isCancelled, false)
        XCTAssertTrue(fixture.recorder.recoveryRecordingURLs.isEmpty)
    }

    /// 恢复进行中后台转写先保存已取消的记录：恢复放弃结果，只有一条记录。
    func testBackgroundTranscriptionSavedFirstMakesTheRestoreFromDictationRecoveryKeepOneRecord() async throws {
        let fixture = try makeFixture()
        fixture.engine.holdsLongRecordings = true
        await cancelSession(fixture, recording: longRecording)
        try await fixture.wait(upTo: 8) { fixture.engine.transcribeCount == 1 }

        var restoreMayFinish = false
        let recovery = try makeRecoveryViewModel(fixture) {
            while !restoreMayFinish { try? await Task.sleep(for: .milliseconds(20)) }
            return "Restored recording"
        }
        recovery.transcribe()
        try await fixture.wait(upTo: 3) { recovery.isProcessing }
        fixture.engine.holdsLongRecordings = false
        try await fixture.wait(upTo: 3) { !self.cancelledRecords(fixture).isEmpty }
        restoreMayFinish = true
        try await fixture.wait(upTo: 3) { !recovery.isProcessing }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(fixture.history.recentRecords.count, 1)
        XCTAssertEqual(fixture.history.recentRecords.first?.isCancelled, true)
        XCTAssertTrue(fixture.recorder.recoveryRecordingURLs.isEmpty)
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
