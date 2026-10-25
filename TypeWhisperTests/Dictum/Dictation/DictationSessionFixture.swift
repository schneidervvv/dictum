import AppKit
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

/// `DictationViewModel` 的完整会话：识别、AI 模型链、插入、快捷键和历史。
/// 识别引擎和 AI 供应商是测试替身，文本插入走私有剪贴板，快捷键只处理测试送入的事件，不产生全局输入。
@MainActor
final class DictationSessionFixture {
    /// 识别像 Qwen3 一样经过识别门，同一时间只运行一次；`holdsLongRecordings` 打开时，长于 2 秒的录音一直占着识别门，
    /// 直到测试关闭它或这次识别被取消。
    final class Engine: NSObject, TranscriptionEnginePlugin, PluginLocalInferenceGateProviding, @unchecked Sendable {
        static var pluginId: String { "com.dictum.test.session.engine" }
        static var pluginName: String { "Session Test Engine" }
        let localInferenceGate = PluginLocalInferenceGate()
        static let longRecordingSampleCount = 2 * Int(AudioRecordingService.targetSampleRate)
        private let lock = NSLock()
        private var _text = "clawed code is ready"
        private var _failure: Error?
        private var _transcribeCount = 0
        private var _transcribedSampleCounts: [Int] = []
        private var _holdsLongRecordings = false
        var text: String {
            get { lock.withLock { _text } }
            set { lock.withLock { _text = newValue } }
        }
        var failure: Error? {
            get { lock.withLock { _failure } }
            set { lock.withLock { _failure = newValue } }
        }
        var holdsLongRecordings: Bool {
            get { lock.withLock { _holdsLongRecordings } }
            set { lock.withLock { _holdsLongRecordings = newValue } }
        }
        var transcribeCount: Int { lock.withLock { _transcribeCount } }
        /// 每次识别收到的采样数，按开始识别的顺序。
        var transcribedSampleCounts: [Int] { lock.withLock { _transcribedSampleCounts } }
        required override init() {}
        func activate(host: HostServices) {}
        func deactivate() {}
        var providerId: String { "session-test-engine" }
        var providerDisplayName: String { "Session Test Engine" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [PluginModelInfo(id: "tiny", displayName: "Tiny")] }
        var selectedModelId: String? { "tiny" }
        func selectModel(_ modelId: String) {}
        var supportsTranslation: Bool { false }
        var supportedLanguages: [String] { ["zh", "en", "ja"] }
        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            try await localInferenceGate.withLock { [self] in
                let (text, failure) = lock.withLock { () -> (String, Error?) in
                    _transcribeCount += 1
                    _transcribedSampleCounts.append(audio.samples.count)
                    return (_text, _failure)
                }
                while holdsLongRecordings, audio.samples.count > Self.longRecordingSampleCount {
                    try await Task.sleep(for: .milliseconds(20))
                }
                if let failure { throw failure }
                return PluginTranscriptionResult(text: text, detectedLanguage: language)
            }
        }
    }

    /// 录音器停止时交出的录音。
    final class RecordedAudio: @unchecked Sendable {
        private let lock = NSLock()
        private var _samples: [Float]
        init(_ samples: [Float]) { _samples = samples }
        var samples: [Float] {
            get { lock.withLock { _samples } }
            set { lock.withLock { _samples = newValue } }
        }
    }

    final class Chain: NSObject, LLMProviderPlugin, @unchecked Sendable {
        static var pluginId: String { "com.dictum.test.session.chain" }
        static var pluginName: String { "Session Test Chain" }
        private let lock = NSLock()
        private var _prompts: [String] = []
        private var _texts: [String] = []
        private var _reply: Result<String, Error> = .success("Polished.")
        required override init() {}
        func activate(host: HostServices) {}
        func deactivate() {}
        var providerName: String { "Session Test Chain" }
        var isAvailable: Bool { true }
        var supportedModels: [PluginModelInfo] { [] }
        var prompts: [String] { lock.withLock { _prompts } }
        var texts: [String] { lock.withLock { _texts } }
        var reply: Result<String, Error> {
            get { lock.withLock { _reply } }
            set { lock.withLock { _reply = newValue } }
        }
        func process(systemPrompt: String, userText: String, model: String?) async throws -> String {
            let reply = lock.withLock { () -> Result<String, Error> in
                _prompts.append(systemPrompt)
                _texts.append(userText)
                return _reply
            }
            return try reply.get()
        }
    }

    struct ProviderFailure: Error, LocalizedError {
        var errorDescription: String? { "所有供应商都失败了" }
    }

    static let preferenceKeys = [
        TranslationLanguageStore.Keys.spoken, TranslationLanguageStore.Keys.targets, TranslationLanguageStore.Keys.current,
        TranslationLanguageStore.Keys.migrated, TranslationLanguageStore.Keys.legacyTarget, TranslationLanguageStore.Keys.legacyTargets,
        UserDefaultsKeys.historyEnabled, UserDefaultsKeys.preserveClipboard, UserDefaultsKeys.saveAudioWithHistory,
        UserDefaultsKeys.historyRetentionDays
    ]

    let model: DictationViewModel
    let engine: Engine
    let chain: Chain
    let history: HistoryService
    let dictionary: DictionaryService
    let modelManager: ModelManagerService
    let promptProcessing: PromptProcessingService
    let snippets: SnippetService
    let hotkeys: HotkeyService
    let recorder: AudioRecordingService
    let recoveryStore: DictationRecoveryAudioStore
    let recent: RecentTranscriptionStore
    let pasteboard: NSPasteboard
    let samples = Array(repeating: Float(0.25), count: Int(AudioRecordingService.targetSampleRate))
    /// 下一次停止录音时交出的录音，默认是 1 秒的 `samples`。
    let recorded: RecordedAudio
    private let retained: [AnyObject]

    init(directory: URL, defaultsSuite suite: String) throws {
        EventBus.shared = EventBus()
        PluginManager.shared = PluginManager(appSupportDirectory: directory)
        let engine = Engine()
        let chain = Chain()
        func loaded(_ id: String, _ instance: any TypeWhisperPlugin) -> LoadedPlugin {
            LoadedPlugin(
                manifest: PluginManifest(id: id, name: id, version: "1.0.0", principalClass: "DictationSessionFixturePlugin"),
                instance: instance, bundle: Bundle.main, sourceURL: directory, isEnabled: true)
        }
        PluginManager.shared.loadedPlugins = [loaded("com.dictum.test.session.engine", engine), loaded("com.dictum.test.session.chain", chain)]

        let modelManager = ModelManagerService()
        modelManager.selectProvider(engine.providerId)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(try JSONEncoder().encode([LLMFallbackPriorityItem(providerId: chain.providerName)]), forKey: UserDefaultsKeys.llmFallbackPriorityList)

        let recoveryStore = DictationRecoveryAudioStore(
            directory: directory.appendingPathComponent("dictation-recovery", isDirectory: true), retentionPolicy: .thirtyDays)
        let recorder = AudioRecordingService(recoveryAudioStore: recoveryStore)
        recorder.hasMicrophonePermissionOverride = true
        recorder.inputAvailabilityOverride = { _ in true }
        recorder.startRecordingOverride = {}
        let recorded = RecordedAudio(samples)
        recorder.stopRecordingOverride = { _ in recorded.samples }

        let insertion = TextInsertionService()
        let pasteboard = NSPasteboard.withUniqueName()
        insertion.pasteboardProvider = { pasteboard }
        insertion.captureActiveAppOverride = { ("Notes", "com.apple.Notes", nil) }
        insertion.accessibilityGrantedOverride = true
        insertion.selectedTextOverride = { nil }
        insertion.focusedTextElementOverride = { nil }
        // 目标应用不公开焦点元素：粘贴照常发出但无法核对，会话按已插入处理。
        insertion.focusedElementHiddenOverride = { true }
        insertion.pasteSimulatorOverride = {}
        insertion.copySimulatorOverride = {}
        insertion.returnSimulatorOverride = {}

        let hotkeys = HotkeyService()
        hotkeys.suspendMonitoring()
        for slot in HotkeySlotType.allCases { hotkeys.setHotkeysForTesting([], for: slot) }
        hotkeys.setHotkeyForTesting(UnifiedHotkey(keyCode: 63, modifierFlags: 0, isFn: true), for: .hybrid)
        hotkeys.setHotkeyForTesting(HotkeyService.defaultTranslationHotkey, for: .translation)
        hotkeys.modifierFlagsStateProvider = { [] }

        let history = HistoryService(appSupportDirectory: directory)
        let recent = RecentTranscriptionStore()
        let dictionary = DictionaryService(appSupportDirectory: directory)
        let snippets = SnippetService(appSupportDirectory: directory)
        let settings = SettingsViewModel(modelManager: modelManager)
        let punctuation = DictationPunctuationProfileStore(defaults: defaults, storageKey: suite)
        let processing = PromptProcessingService(userDefaults: defaults)
        let sounds = SoundService()
        let media = MediaPlaybackService(startListening: false)
        let model = DictationViewModel(
            audioRecordingService: recorder, textInsertionService: insertion, hotkeyService: hotkeys, modelManager: modelManager,
            settingsViewModel: settings, historyService: history, recentTranscriptionStore: recent,
            profileService: ProfileService(appSupportDirectory: directory), workflowService: WorkflowService(appSupportDirectory: directory),
            translationService: nil, audioDuckingService: AudioDuckingService(), dictionaryService: dictionary,
            targetAppCorrectionLearningService: TargetAppCorrectionLearningService(
                textInsertionService: insertion, textDiffService: TextDiffService(), dictionaryService: dictionary,
                defaults: defaults, persistLatestAttempt: false),
            snippetService: snippets, soundService: sounds,
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
        model.cancellationBehavior = .singleEscape

        self.model = model
        self.engine = engine
        self.chain = chain
        self.history = history
        self.dictionary = dictionary
        self.modelManager = modelManager
        self.promptProcessing = processing
        self.snippets = snippets
        self.hotkeys = hotkeys
        self.recorder = recorder
        self.recoveryStore = recoveryStore
        self.pasteboard = pasteboard
        self.recent = recent
        self.recorded = recorded
        retained = [insertion, modelManager, settings, processing, sounds, media]
    }

    /// 从菜单栏、Raycast 或本机接口开始会话，等录音开始。
    func startFromAPI(mode: DictationMode) async -> UUID {
        let sessionID = model.apiStartRecording(mode: mode)
        await model.testingWaitForRecordingStart()
        return sessionID
    }

    func waitUntilCompleted(_ sessionID: UUID) async throws -> DictationSessionSnapshot? {
        for _ in 0..<160 where model.apiDictationSession(id: sessionID)?.status != .completed {
            try await Task.sleep(for: .milliseconds(25))
        }
        await model.testingWaitForPostInsertionPersistence()
        return model.apiDictationSession(id: sessionID)
    }

    /// 等条件成立，最多等 `seconds` 秒；取消窗口本身是 3 秒。
    func wait(upTo seconds: Double, until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    func flagsChanged(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, device: UInt64 = 0) throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down))
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: flags.rawValue | device)
        _ = hotkeys.processEventForTesting(try XCTUnwrap(NSEvent(cgEvent: event)), source: .monitor)
    }

    static let fnKey: CGKeyCode = 63
    static let leftShift: CGKeyCode = 0x38
    static let deviceLeftShift: UInt64 = 0x2
    static let rightOption: CGKeyCode = 0x3D
    static let deviceRightOption: UInt64 = 0x40
}

/// 每个测试使用自己的临时文件夹和偏好设置套件，结束时恢复改过的标准偏好设置。
@MainActor
class DictationSessionTestCase: XCTestCase {
    private(set) var directory: URL!
    private var savedDefaults: [String: Any] = [:]
    private var previousPluginManager: PluginManager?

    override func setUp() async throws {
        try await super.setUp()
        directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-session-fixture")
        previousPluginManager = PluginManager.shared
        let defaults = UserDefaults.standard
        savedDefaults = Dictionary(uniqueKeysWithValues: DictationSessionFixture.preferenceKeys.compactMap { key in
            defaults.object(forKey: key).map { (key, $0) }
        })
        defaults.set(true, forKey: UserDefaultsKeys.historyEnabled)
        defaults.removeObject(forKey: UserDefaultsKeys.historyRetentionDays)
        defaults.set(false, forKey: UserDefaultsKeys.preserveClipboard)
        defaults.set(true, forKey: UserDefaultsKeys.saveAudioWithHistory)
        defaults.set(true, forKey: TranslationLanguageStore.Keys.migrated)
        defaults.set("en", forKey: TranslationLanguageStore.Keys.spoken)
        defaults.set(["ja"], forKey: TranslationLanguageStore.Keys.targets)
        defaults.removeObject(forKey: TranslationLanguageStore.Keys.current)
        TranslationLanguageStore.shared.reload()
    }

    override func tearDown() async throws {
        let defaults = UserDefaults.standard
        for key in DictationSessionFixture.preferenceKeys {
            if let value = savedDefaults[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
        }
        TranslationLanguageStore.shared.reload()
        PluginManager.shared = previousPluginManager
        TestSupport.remove(directory)
        try await super.tearDown()
    }

    func makeFixture() throws -> DictationSessionFixture {
        let suite = "dictum-session-fixture-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return try DictationSessionFixture(directory: directory, defaultsSuite: suite)
    }
}
