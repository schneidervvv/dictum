import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

/// 停止录音后，仍在运行的预览发来的文字不再交给语音条：最终识别文字替换预览，
/// 迟到的预览文字接在后面会让同一句话出现两遍。
@MainActor
final class StreamingPreviewAfterStopTests: XCTestCase {
    private actor Gate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func wait() async {
            isWaiting = true
            await withCheckedContinuation { continuation = $0 }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    /// 第一次预览一直运行到被放行，放行时才报出文字，就像录音停止时还在识别的预览。
    private final class SlowPreviewPlugin: NSObject, TranscriptionEnginePlugin, @unchecked Sendable {
        static var pluginId: String { "com.dictum.test.slowpreview" }
        static var pluginName: String { "Slow Preview" }
        var providerId: String { "slow-preview" }
        var providerDisplayName: String { "Slow Preview" }
        var isConfigured: Bool { true }
        var transcriptionModels: [PluginModelInfo] { [] }
        var selectedModelId: String? { nil }
        var supportsTranslation: Bool { false }
        var supportsStreaming: Bool { true }
        var supportedLanguages: [String] { ["zh"] }
        let gate = Gate()
        let lateText: String

        required override init() {
            lateText = ""
            super.init()
        }

        init(lateText: String) {
            self.lateText = lateText
            super.init()
        }

        func activate(host: HostServices) {}
        func deactivate() {}
        func selectModel(_ modelId: String) {}

        func transcribe(audio: AudioData, language: String?, translate: Bool, prompt: String?) async throws -> PluginTranscriptionResult {
            await gate.wait()
            return PluginTranscriptionResult(text: lateText, detectedLanguage: language)
        }

        func transcribe(
            audio: AudioData,
            language: String?,
            translate: Bool,
            prompt: String?,
            onProgress: @Sendable @escaping (String) -> Bool
        ) async throws -> PluginTranscriptionResult {
            let result = try await transcribe(audio: audio, language: language, translate: translate, prompt: prompt)
            _ = onProgress(result.text)
            return result
        }
    }

    func testPreviewTextArrivingAfterStopNeverReachesTheVoiceBar() async throws {
        let appSupportDirectory = try TestSupport.makeTemporaryDirectory()
        defer { TestSupport.remove(appSupportDirectory) }

        let plugin = SlowPreviewPlugin(lateText: "我现在已经到楼下了，就是你不用着急。")
        let previousPluginManager = PluginManager.shared
        defer { PluginManager.shared = previousPluginManager }
        PluginManager.shared = PluginManager(appSupportDirectory: appSupportDirectory)
        PluginManager.shared.loadedPlugins = [LoadedPlugin(
            manifest: PluginManifest(id: SlowPreviewPlugin.pluginId, name: "Slow Preview", version: "1.0.0", principalClass: "SlowPreviewPlugin"),
            instance: plugin, bundle: Bundle.main, sourceURL: appSupportDirectory, isEnabled: true)]
        let modelManager = ModelManagerService()
        modelManager.selectProvider(plugin.providerId)

        let handler = StreamingHandler(
            modelManager: modelManager,
            bufferProvider: { [] },
            recentBufferProvider: { _ in Array(repeating: 0.5, count: 16_000) },
            bufferDeltaProvider: { _ in ([], 0) },
            bufferedDurationProvider: { 1.0 }
        )
        defer { handler.stop() }

        var finishCalled = false
        var updatesBeforeFinish: [String] = []
        var updatesAfterFinish: [String] = []
        handler.onPartialTextUpdate = { text in
            if finishCalled { updatesAfterFinish.append(text) } else { updatesBeforeFinish.append(text) }
        }
        handler.start(
            streamPrompt: "",
            engineOverrideId: plugin.providerId,
            selectedProviderId: plugin.providerId,
            languageSelection: .exact("zh"),
            task: .transcribe,
            cloudModelOverride: nil,
            allowLiveTranscription: true,
            stateCheck: { true }
        )

        var previewStarted = false
        for _ in 0..<80 {
            if await plugin.gate.isWaiting { previewStarted = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(previewStarted)
        guard previewStarted else { return }

        finishCalled = true
        let finishTask = Task { @MainActor in await handler.finish() }
        try await Task.sleep(for: .milliseconds(100))
        await plugin.gate.release()
        _ = await finishTask.value
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(updatesBeforeFinish, [])
        XCTAssertEqual(updatesAfterFinish, [], "停止后迟到的预览文字不再更新语音条")
    }
}
