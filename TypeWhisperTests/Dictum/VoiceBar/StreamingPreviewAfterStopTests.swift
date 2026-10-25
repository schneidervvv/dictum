import os
import TypeWhisperPluginSDK
import XCTest
@testable import TypeWhisper

/// 停止录音后，仍在运行的预览发来的文字不再交给语音条：最终识别文字替换预览，
/// 迟到的预览文字接在后面会让同一句话出现两遍。
@MainActor
final class StreamingPreviewAfterStopTests: XCTestCase {
    /// 现场会话在结束时再报一次进度，就像识别在收尾时发来的迟到预览文字。
    private final class SlowLiveSession: LiveTranscriptionSession, @unchecked Sendable {
        let lateText: String
        let onProgress: @Sendable (String) -> Bool

        init(lateText: String, onProgress: @escaping @Sendable (String) -> Bool) {
            self.lateText = lateText
            self.onProgress = onProgress
        }

        func appendAudio(samples: [Float]) async throws {}

        func finish() async throws -> PluginTranscriptionResult {
            _ = onProgress(lateText)
            return PluginTranscriptionResult(text: lateText, detectedLanguage: "zh")
        }

        func cancel() async {}
    }

    private final class SlowPreviewPlugin: NSObject, TranscriptionEnginePlugin, LiveTranscriptionCapablePlugin, @unchecked Sendable {
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
            PluginTranscriptionResult(text: lateText, detectedLanguage: language)
        }

        func createLiveTranscriptionSession(
            language: String?,
            translate: Bool,
            prompt: String?,
            onProgress: @Sendable @escaping (String) -> Bool
        ) async throws -> any LiveTranscriptionSession {
            SlowLiveSession(lateText: lateText, onProgress: onProgress)
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

        // 第一次轮询送一秒语音，预览音频门记录到说话；之后没有新音频。
        let speechSent = OSAllocatedUnfairLock(initialState: false)
        let handler = StreamingHandler(
            modelManager: modelManager,
            bufferProvider: { [] },
            recentBufferProvider: { _ in Array(repeating: 0.5, count: 16_000) },
            bufferDeltaProvider: { _ in
                speechSent.withLock { sent in
                    if sent { return ([], 16_000) }
                    sent = true
                    return (Array(repeating: 0.5, count: 16_000), 16_000)
                }
            },
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

        var sessionOpened = false
        for _ in 0..<80 {
            if handler.hasActiveLiveTranscriptionSession { sessionOpened = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(sessionOpened)
        guard sessionOpened else { return }

        finishCalled = true
        let outcome = await handler.finish()
        try await Task.sleep(for: .milliseconds(300))

        guard case .finished(let result) = outcome else {
            return XCTFail("现场会话应正常结束，实际 \(outcome)")
        }
        XCTAssertTrue(result.text.contains("楼下"), "最终结果是识别文字：\(result.text)")
        XCTAssertEqual(updatesBeforeFinish, [])
        XCTAssertEqual(updatesAfterFinish, [], "停止后迟到的预览文字不再更新语音条")
    }
}
