import AppKit
import Combine
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

/// 阶段 6 实机测试发现的语音条问题：润色中、翻译中状态的文字，Esc 取消的默认次数与提示，
/// 菜单栏翻译会话的状态行。识别引擎是测试里的插件，文本插入走私有剪贴板。
@MainActor
final class VoiceBarLiveFixesTests: XCTestCase {
    private final class Engine: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.dictum.test.voicebarlive.engine" }
        static var pluginName: String { "Voice Bar Live Test Engine" }
        var text = ""
        required override init() {}
        func activate(host: HostServices) {}
        func deactivate() {}
        var providerId: String { "voicebar-live-test-engine" }
        var providerDisplayName: String { "Voice Bar Live Test Engine" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
        var selectedModelId: String? { "tiny" }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }
        var supportedLanguages: [String] { ["zh", "en"] }
        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            PluginTranscriptionResult(text: text, detectedLanguage: language)
        }
    }

    private var directory: URL!
    private var previousPluginManager: PluginManager?
    private var savedDefaults: [String: Any] = [:]
    private var retained: [AnyObject] = []
    private static let cancellationKeys = [UserDefaultsKeys.cancellationBehavior, UserDefaultsKeys.requireSecondEscapeToCancelRecording]

    override func setUp() async throws {
        try await super.setUp()
        directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-voicebar-live")
        previousPluginManager = PluginManager.shared
        let defaults = UserDefaults.standard
        savedDefaults = Dictionary(uniqueKeysWithValues: Self.cancellationKeys.compactMap { key in defaults.object(forKey: key).map { (key, $0) } })
        for key in Self.cancellationKeys { defaults.removeObject(forKey: key) }
    }

    override func tearDown() async throws {
        let defaults = UserDefaults.standard
        for key in Self.cancellationKeys {
            if let value = savedDefaults[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        PluginManager.shared = previousPluginManager
        retained = []
        TestSupport.remove(directory)
        try await super.tearDown()
    }

    private func makeModel(engineText: String = "") throws -> DictationViewModel {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: directory)
        let engine = Engine()
        engine.text = engineText
        PluginManager.shared.loadedPlugins = [LoadedPlugin(
            manifest: PluginManifest(id: "com.dictum.test.voicebarlive", name: "engine", version: "1.0.0", principalClass: "Engine"),
            instance: engine, bundle: Bundle.main, sourceURL: directory, isEnabled: true)]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(engine.providerId)
        let suite = "dictum-voicebar-live-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("[]".utf8), forKey: UserDefaultsKeys.llmFallbackPriorityList)

        let recorder = AudioRecordingService()
        recorder.hasMicrophonePermissionOverride = true
        recorder.inputAvailabilityOverride = { _ in true }
        recorder.startRecordingOverride = {}
        recorder.stopRecordingOverride = { _ in Array(repeating: 0.25, count: Int(AudioRecordingService.targetSampleRate)) }

        let insertion = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        insertion.pasteboardProvider = { pasteboard }
        insertion.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }
        insertion.accessibilityGrantedOverride = true
        insertion.selectedTextOverride = { nil }
        insertion.pasteSimulatorOverride = {}

        let hotkeys = HotkeyService()
        hotkeys.suspendMonitoring()
        let workflows = WorkflowService(appSupportDirectory: directory)
        let dictionary = DictionaryService(appSupportDirectory: directory)
        let settings = SettingsViewModel(modelManager: modelManager)
        let punctuation = DictationPunctuationProfileStore(defaults: defaults, storageKey: suite)
        let processing = PromptProcessingService(userDefaults: defaults)
        let sounds = SoundService()
        let media = MediaPlaybackService(startListening: false)
        let model = DictationViewModel(
            audioRecordingService: recorder, textInsertionService: insertion, hotkeyService: hotkeys, modelManager: modelManager,
            settingsViewModel: settings, historyService: HistoryService(appSupportDirectory: directory),
            recentTranscriptionStore: RecentTranscriptionStore(),
            profileService: ProfileService(appSupportDirectory: directory), workflowService: workflows, translationService: nil,
            audioDuckingService: AudioDuckingService(), dictionaryService: dictionary,
            targetAppCorrectionLearningService: TargetAppCorrectionLearningService(
                textInsertionService: insertion, textDiffService: TextDiffService(), dictionaryService: dictionary,
                defaults: defaults, persistLatestAttempt: false),
            snippetService: SnippetService(appSupportDirectory: directory), soundService: sounds,
            audioDeviceService: AudioDeviceService(initialInputDevices: [], monitorDeviceChanges: false, probeCompatibilities: false),
            promptActionService: PromptActionService(appSupportDirectory: directory),
            promptProcessingService: processing, appFormatterService: AppFormatterService(),
            punctuationStrategyResolver: PunctuationStrategyResolver(profileStore: punctuation),
            speechPunctuationService: SpeechPunctuationService(rulesLoader: PunctuationRulesLoader()),
            accessibilityAnnouncementService: AccessibilityAnnouncementService(), errorLogService: ErrorLogService(appSupportDirectory: directory),
            mediaPlaybackService: media)
        model.soundFeedbackEnabled = false
        model.audioDuckingEnabled = false
        model.mediaPauseEnabled = false
        model.preserveClipboard = false
        retained = [recorder, insertion, modelManager, settings, processing, sounds, media, dictionary, workflows, hotkeys, engine]
        return model
    }

    /// 录音中显示预览，说完后记录语音条在整个处理过程中拿到的文字。
    private func textsDuringProcessing(mode: DictationMode, preview: String, final: String) async throws -> [String] {
        let model = try makeModel(engineText: final)
        let sessionID = model.apiStartRecording(mode: mode)
        await model.testingWaitForRecordingStart()
        model.partialText = preview

        var texts: [String] = []
        let subscription = model.$partialText.sink { texts.append($0) }
        defer { subscription.cancel() }
        _ = model.apiStopRecording()
        for _ in 0..<120 {
            if model.apiDictationSession(id: sessionID)?.status == .completed { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        await model.testingWaitForPostInsertionPersistence()
        return texts
    }

    // MARK: - 润色中、翻译中显示最终识别文字

    func testPolishingShowsTheFinalTranscriptInsteadOfThePreview() async throws {
        let preview = "第一，产品。，产品方案；第二，预算表"
        let final = "第一，产品方案；第二，预算表。"
        let texts = try await textsDuringProcessing(mode: .dictation, preview: preview, final: final)

        XCTAssertTrue(texts.contains(final), "处理开始后语音条拿到最终识别文字：\(texts)")
        XCTAssertFalse(texts.contains { $0.contains(preview) && $0.contains(final) }, "预览和最终文字没有接在一起：\(texts)")
    }

    func testTranslationShowsTheFinalTranscriptOnceWithoutRepeatingTheFirstSentence() async throws {
        let preview = "嗯，那个，我现在。，我现在已经在楼下了，就是你。"
        let final = "嗯，那个，我现在已经到楼下了，就是你不用着急，慢慢来就好。"
        let texts = try await textsDuringProcessing(mode: .translation, preview: preview, final: final)

        XCTAssertTrue(texts.contains(final), "处理开始后语音条拿到最终识别文字：\(texts)")
        for text in texts where text.contains(final) {
            XCTAssertEqual(text.components(separatedBy: "我现在已经").count - 1, 1, "同一句话没有重复：\(text)")
            XCTAssertFalse(text.contains(preview), "最终文字替换了预览：\(text)")
        }
    }

    func testVoiceBarCarriesOnlyTheFinalTranscriptWhileProcessing() {
        let presentation = VoiceBarPresentation()
        let preview = StreamingHandler.Preview(confirmedPrefix: "第一，产品。", tentativeTail: "，产品方案")
        presentation.updateTranscript(recording: true, partialText: "第一，产品。，产品方案", preview: preview)
        XCTAssertEqual(presentation.transcript, "第一，产品。，产品方案")

        presentation.updateTranscript(recording: false, partialText: "第一，产品方案。", preview: preview)
        XCTAssertEqual(presentation.text, "第一，产品方案。")
        XCTAssertEqual(presentation.tentativeText, "")
        XCTAssertEqual(presentation.transcript, "第一，产品方案。")
    }

    // MARK: - Esc

    func testOneEscCancelsByDefaultAndShowsCancelledWithUndo() async throws {
        let model = try makeModel()
        XCTAssertEqual(model.cancellationBehavior, .singleEscape)
        _ = model.apiStartRecording()
        await model.testingWaitForRecordingStart()
        XCTAssertEqual(model.state, .recording)

        model.handleCancelHotkey()

        let presentation = VoiceBarPresentation()
        presentation.refresh(model)
        guard case .cancelled(let remaining) = presentation.state else {
            return XCTFail("按一次 Esc 显示已取消 · 恢复，实际 \(presentation.state)")
        }
        XCTAssertGreaterThan(remaining, 0)
        XCTAssertNotNil(model.cancelledRecordingDeadline)
        XCTAssertFalse(presentation.showsCancelHint)
    }

    func testTwoPressModeShowsAHintOnTheFirstEscAndCancelsOnTheSecond() async throws {
        let model = try makeModel()
        model.cancellationBehavior = .doubleEscape
        _ = model.apiStartRecording()
        await model.testingWaitForRecordingStart()

        let presentation = VoiceBarPresentation()
        presentation.refresh(model)
        XCTAssertFalse(presentation.showsCancelHint)

        model.handleCancelHotkey()
        presentation.refresh(model)
        XCTAssertTrue(presentation.showsCancelHint, "第一次按下后语音条提示再按一次")
        XCTAssertEqual(model.state, .recording)
        XCTAssertNil(model.cancelledRecordingDeadline)

        model.handleCancelHotkey()
        presentation.refresh(model)
        XCTAssertFalse(presentation.showsCancelHint)
        guard case .cancelled = presentation.state else {
            return XCTFail("第二次按下取消，实际 \(presentation.state)")
        }
    }

    func testCancelHintCopyExistsInBothLanguages() {
        XCTAssertEqual(
            String(localized: LocalizedStringResource("Press esc again to cancel", table: "DictumHome", locale: Locale(identifier: "zh-Hans"))),
            "再按一次 esc 取消")
        XCTAssertEqual(
            String(localized: LocalizedStringResource("Press esc again to cancel", table: "DictumHome", locale: Locale(identifier: "en"))),
            "Press esc again to cancel")
    }

    // MARK: - 菜单栏状态行

    func testMenuBarStatusNamesTheSessionMode() {
        let zh = Locale(identifier: "zh-Hans")
        let en = Locale(identifier: "en")
        XCTAssertEqual(String(localized: MenuBarRecordingStatus.title(for: .dictation, locale: zh)), "正在听写")
        XCTAssertEqual(String(localized: MenuBarRecordingStatus.title(for: .translation, locale: zh)), "正在翻译")
        XCTAssertEqual(String(localized: MenuBarRecordingStatus.title(for: .dictation, locale: en)), "Dictating")
        XCTAssertEqual(String(localized: MenuBarRecordingStatus.title(for: .translation, locale: en)), "Translating")
    }
}
