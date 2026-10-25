import XCTest
@testable import TypeWhisper

/// 语音条和菜单栏在听写、翻译、撤销和恢复过程中展示的每条动态文案，在
/// zh-Hans 界面下都必须解析出中文。测试把应用语言设为 zh-Hans，检查每个
/// 目录键都有简体中文值，并在结束时恢复语言设置。8a5613c8 上没有这些值，
/// 断言随之失败。
@MainActor
final class VoiceBarZhHansMessageTests: XCTestCase {
    private var originalPreferredAppLanguage: String?

    override func setUp() {
        super.setUp()
        originalPreferredAppLanguage = UserDefaults.standard.string(forKey: UserDefaultsKeys.preferredAppLanguage)
        UserDefaults.standard.set("zh-Hans", forKey: UserDefaultsKeys.preferredAppLanguage)
    }

    override func tearDown() {
        if let originalPreferredAppLanguage {
            UserDefaults.standard.set(originalPreferredAppLanguage, forKey: UserDefaultsKeys.preferredAppLanguage)
        } else {
            UserDefaults.standard.removeObject(forKey: UserDefaultsKeys.preferredAppLanguage)
        }
        super.tearDown()
    }

    /// 撤销和恢复的反馈：DictationUndoService.Failure.feedbackMessage
    /// 与 DictationViewModel 的两条成功提示。
    func testUndoAndRestoreFeedbackResolvesToChinese() throws {
        try assertChineseCatalogValues([
            "There is no recent dictation to change.",
            "The inserted text already matches the raw transcript.",
            "The last dictation is too old to change safely.",
            "Dictation is active. Try again when it finishes.",
            "The last dictation is still being saved. Try again shortly.",
            "The text may have changed, but the result couldn't be verified. Check the text field.",
            "The text field can't be verified right now, so nothing was changed.",
            "The app or text field changed since insertion, so nothing was changed.",
            "The caret moved since insertion, so nothing was changed.",
            "The inserted text was edited, so nothing was changed.",
            "The text couldn't be changed.",
            "Last dictation undone.",
            "Raw transcript restored.",
        ])
    }

    /// 录音和输入设备错误：AudioRecordingError、SelectedInputDeviceError
    /// 与录音过程的状态提示。
    func testRecordingErrorFeedbackResolvesToChinese() throws {
        try assertChineseCatalogValues([
            "Microphone permission denied. Please grant access in System Settings.",
            "No audio data was recorded.",
            "Failed to start audio engine: %@",
            "Microphone permission required.",
            "No mic detected.",
            "Microphone disconnected",
            "Microphone disconnected. Falling back to system default.",
            "Selected input device is no longer available.",
            "The selected microphone conflicts with your current audio routing. Disconnect Bluetooth or choose a different input.",
            "This microphone can't be used by dictum for preview or recording.",
            "The Bluetooth microphone sent only silence. Check that it is not muted, or reconnect it.",
            "The microphone sent only silence. Check that it is not muted and dictum has microphone access.",
            "Too short, hold the hotkey a bit longer",
            "No speech detected",
            "No speech recognized",
            "Cancelled",
            "Recording discarded because additional keys were pressed",
            "Press Esc again to cancel recording",
            "Press Esc again to cancel transcription",
            "The recording was saved to Dictation Recovery.",
        ])
    }

    /// 识别错误：TranscriptionEngineError 的目录键、恢复回退与超时文案，
    /// 以及云端识别插件上报的 PluginTranscriptionError。
    func testTranscriptionErrorFeedbackResolvesToChinese() throws {
        try assertChineseCatalogValues([
            "%@ is not available.",
            "Check its settings page in the sidebar or choose another engine under Settings > Dictation.",
            "The selected model is not ready yet. Download or load it on the engine's settings page, or choose another model under Settings > Dictation.",
            "Apple Speech needs a language model. Open Apple Speech in the settings sidebar and select a language model, or choose a specific transcription language.",
            "Transcription failed.",
            "Please try again.",
            "Failed to load the selected model.",
            "Try again, or choose another model under Settings > Dictation.",
            "Failed to download the model.",
            "Check your connection and try again.",
            "The selected transcription engine",
            "Primary transcription failed: %@. Recovery fallback failed: %@",
            "Transcription timed out after %d seconds.",
            "Cloud provider not configured. Please set an API key.",
            "No cloud model selected.",
            "Invalid API key. Please check your API key and try again.",
            "Rate limit or quota exceeded. Check your provider's usage limits and credit balance, or wait and try again.",
            "Audio file too large for the API.",
            "API error: %@",
            "Network error: %@",
        ])
    }

    /// 插入失败、恢复入口和润色回退的反馈。
    func testInsertionAndFallbackFeedbackResolvesToChinese() throws {
        try assertChineseCatalogValues([
            "No text field detected",
            "The text field changed",
            "Or press %@",
            "Failed to paste text: %@",
            "history.retranscribe.busy",
            "AI post-processing failed — raw transcription inserted",
            "Enter submission is unavailable. Check Accessibility access and restart dictum, or choose another Enter option.",
        ])
    }

    /// 语音条固定状态文案与 dictum 各字符串表里的会话文案。
    func testDictumTableMessagesResolveToChinese() throws {
        try assertChineseCatalogValues(
            [
                "Getting ready",
                "Esc again to cancel",
                "Cancelled",
                "Undo",
                "Done",
                "Cancel",
                "Retry",
                "Settings",
                "Open Settings",
                "Open Dictation Recovery",
                "Inserted · %lld words",
                "Copied. No text field found.",
                "Polishing failed. Original inserted.",
                "Microphone unavailable",
                "Didn't hear anything",
                "Downloading speech model",
                "Speech model not downloaded",
                "View",
                "No AI model connected. Original inserted.",
                "Dictating",
                "menu.status.translating",
                "Close",
            ],
            catalog: "TypeWhisper/Dictum/Resources/DictumHome.xcstrings"
        )
        try assertChineseCatalogValues(
            [
                "The speech model is downloading.",
                "The speech model is not downloaded.",
                "Connection lost, %@ downloaded",
            ],
            catalog: "TypeWhisper/Dictum/Resources/DictumSpeech.xcstrings"
        )
        try assertChineseCatalogValues(
            [
                "translation.failed.inserted",
                "translation.retry.replaced",
                "translation.retry.copied",
                "No AI model connected.",
                "Translation failed. What you said was inserted.",
                "Auto",
            ],
            catalog: "TypeWhisper/Dictum/Resources/DictumTranslation.xcstrings"
        )
        try assertChineseCatalogValues(
            [
                "polish.retry.replaced",
                "polish.retry.copied",
            ],
            catalog: "TypeWhisper/Dictum/Resources/DictumStyle.xcstrings"
        )
    }

    /// 由 zh: 参数直接提供中文的消息在产出时就已解析。
    func testLocalizedAppTextMessagesResolveToChinese() throws {
        let hasHan: (String) -> Bool = { $0.range(of: "\\p{Han}", options: .regularExpression) != nil }
        XCTAssertTrue(hasHan(TranscriptionEngineError.noEngineSelected.localizedDescription))
        XCTAssertTrue(hasHan(AccessibilityPermissionPane.enableInSystemSettingsText()))
    }

    private func assertChineseCatalogValues(
        _ keys: [String],
        catalog: String = "TypeWhisper/Resources/Localizable.xcstrings",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = TestSupport.repoRoot.appendingPathComponent(catalog)
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any],
            "\(catalog) is not a JSON object",
            file: file,
            line: line
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any], file: file, line: line)
        for key in keys {
            let entry = try XCTUnwrap(
                strings[key] as? [String: Any],
                "Missing catalog entry for \(key) in \(catalog)",
                file: file,
                line: line
            )
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                "Missing localizations for \(key) in \(catalog)",
                file: file,
                line: line
            )
            let chinese = try XCTUnwrap(
                localizations["zh-Hans"] as? [String: Any],
                "Missing zh-Hans localization for \(key) in \(catalog)",
                file: file,
                line: line
            )
            let unit = try XCTUnwrap(
                chinese["stringUnit"] as? [String: Any],
                "Missing stringUnit for \(key) in \(catalog)",
                file: file,
                line: line
            )
            let value = try XCTUnwrap(
                unit["value"] as? String,
                "Missing value for \(key) in \(catalog)",
                file: file,
                line: line
            )
            XCTAssertNotEqual(
                value,
                key,
                "zh-Hans value of \(key) in \(catalog) still reads in English",
                file: file,
                line: line
            )
            XCTAssertNotNil(
                value.range(of: "\\p{Han}", options: .regularExpression),
                "zh-Hans value of \(key) in \(catalog) contains no Chinese characters: \(value)",
                file: file,
                line: line
            )
            for placeholder in ["%@", "%d", "%lld"] where key.contains(placeholder) {
                XCTAssertTrue(
                    value.contains(placeholder),
                    "zh-Hans value of \(key) in \(catalog) lost the \(placeholder) placeholder: \(value)",
                    file: file,
                    line: line
                )
            }
        }
    }
}
