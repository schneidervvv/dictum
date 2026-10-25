import Foundation
import TypeWhisperPluginSDK
import XCTest
@_spi(Testing) import TypeWhisperPluginSDKTesting
@testable import OpenRouterPlugin

final class OpenRouterPluginTests: XCTestCase {
    override func tearDown() {
        PluginHTTPClientTestHarness.reset()
        super.tearDown()
    }

    func testTranscriptionCapabilitiesAndFallbackModels() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenRouterPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.providerId, "openrouter")
        XCTAssertEqual(plugin.providerDisplayName, "OpenRouter")
        XCTAssertFalse(plugin.supportsTranslation)
        XCTAssertFalse(plugin.supportsStreaming)
        XCTAssertEqual(plugin.dictionaryTermsSupport, .unsupported)
        XCTAssertEqual(plugin.selectedModelId, "openai/whisper-1")
        XCTAssertEqual(
            plugin.transcriptionModels.map(\.id),
            [
                "openai/whisper-1",
                "openai/gpt-4o-mini-transcribe",
                "openai/gpt-4o-transcribe",
                "openai/whisper-large-v3",
            ]
        )
    }

    func testSelectedTranscriptionModelPersistsAcrossActivation() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        plugin.selectModel("openai/gpt-4o-transcribe")
        plugin.deactivate()

        let reloaded = OpenRouterPlugin()
        reloaded.activate(host: host)

        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "openai/gpt-4o-transcribe")
        XCTAssertEqual(reloaded.selectedModelId, "openai/gpt-4o-transcribe")
    }

    func testInvalidPersistedModelSelectionsFallbackAndPersistValidDefaults() throws {
        let host = try PluginTestHostServices(defaults: [
            "selectedModel": " retired-stt-model ",
            "selectedLLMModel": "retired-llm-model",
        ])
        let plugin = OpenRouterPlugin()

        plugin.activate(host: host)

        XCTAssertEqual(plugin.selectedModelId, "openai/whisper-1")
        XCTAssertEqual(plugin.selectedLLMModelId, "google/gemma-4-26b-a4b-it:free")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "openai/whisper-1")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "google/gemma-4-26b-a4b-it:free")
    }

    func testProcessSendsLocalChatRequestAndParsesText() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)
        plugin.setLLMTemperatureMode(.custom)
        plugin.setLLMTemperatureValue(0.7)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"choices":[{"message":{"content":" hello from chat \n"}}]}"#.utf8),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/chat/completions", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.process(
            systemPrompt: "System prompt",
            userText: "User text",
            model: nil
        )

        XCTAssertEqual(result, "hello from chat")

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openrouter-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 30)

        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["model"] as? String, "google/gemma-4-26b-a4b-it:free")
        XCTAssertEqual(body["max_tokens"] as? Int, 4096)
        XCTAssertEqual(body["temperature"] as? Double, 0.7)

        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [
            ["role": "system", "content": "System prompt"],
            ["role": "user", "content": "User text"],
        ])
    }

    func testParseChatResponseThrowsWhenReplyStoppedAtTokenLimit() {
        XCTAssertThrowsError(try OpenRouterPlugin.parseChatResponse(
            Data(#"{"choices":[{"message":{"content":"half a sen"},"finish_reason":"length"}]}"#.utf8)
        )) { error in
            guard let pluginError = error as? PluginChatError,
                  case .apiError(let message) = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("cut off"), message)
        }
    }

    func testChatHTTPErrorMapping() {
        XCTAssertThrowsError(try OpenRouterPlugin.validateChatResponse(
            data: Data(#"{"error":{"message":"bad key"}}"#.utf8),
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/chat/completions", statusCode: 401)
        )) { error in
            guard let pluginError = error as? PluginChatError,
                  case .invalidApiKey = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try OpenRouterPlugin.validateChatResponse(
            data: Data(#"{"error":{"message":"slow down"}}"#.utf8),
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/chat/completions", statusCode: 429)
        )) { error in
            guard let pluginError = error as? PluginChatError,
                  case .rateLimited = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try OpenRouterPlugin.validateChatResponse(
            data: Data(#"{"error":{"message":"server failed"}}"#.utf8),
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/chat/completions", statusCode: 500)
        )) { error in
            guard let pluginError = error as? PluginChatError,
                  case .apiError(let message) = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "server failed")
        }
    }

    func testLLMAndTranscriptionModelFetchesUseSeparateEndpointsAndCaches() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        """
                        {
                          "data": [
                            {
                              "id": "openai/whisper-1",
                              "name": "OpenAI: Whisper 1",
                              "architecture": { "modality": "audio->transcription" }
                            },
                            {
                              "id": "openai/gpt-4o",
                              "name": "OpenAI: GPT-4o",
                              "pricing": { "prompt": "0.0000025", "completion": "0.00001" },
                              "architecture": { "modality": "text->text" }
                            }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/models", statusCode: 200)
                ),
                .success(
                    Data(
                        """
                        {
                          "data": [
                            {
                              "id": "z-provider/z-stt",
                              "name": "Zulu STT",
                              "pricing": { "prompt": "0.40", "completion": "0" },
                              "architecture": { "modality": "audio->transcription" }
                            },
                            {
                              "id": "a-provider/a-stt",
                              "name": "Alpha STT",
                              "pricing": { "prompt": "0.20", "completion": "0" },
                              "architecture": { "modality": "audio->transcription" }
                            }
                          ]
                        }
                        """.utf8
                    ),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/models?output_modalities=transcription", statusCode: 200)
                ),
            ])
        }

        let llmModels = await plugin.fetchLLMModels()
        let transcriptionModels = await plugin.fetchTranscriptionModels()
        plugin.setFetchedLLMModels(llmModels)
        plugin.setFetchedTranscriptionModels(transcriptionModels)

        XCTAssertEqual(llmModels.map(\.id), ["openai/gpt-4o"])
        XCTAssertEqual(transcriptionModels.map(\.id), ["a-provider/a-stt", "z-provider/z-stt"])
        XCTAssertEqual(plugin.supportedModels.map(\.id), ["openai/gpt-4o"])
        XCTAssertEqual(plugin.transcriptionModels.map(\.id), ["a-provider/a-stt", "z-provider/z-stt"])

        let requests = try XCTUnwrap(store.sessions.first?.requestedRequests)
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/v1/models", "/api/v1/models"])
        XCTAssertEqual(requests.map { $0.url?.query }, [nil, "output_modalities=transcription"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") }, [
            "Bearer openrouter-key",
            "Bearer openrouter-key",
        ])
        XCTAssertNotNil(host.userDefault(forKey: "fetchedModels") as? Data)
        XCTAssertNotNil(host.userDefault(forKey: "fetchedTranscriptionModels") as? Data)
    }

    func testTranscribeFailsWithoutAPIKey() async throws {
        let host = try PluginTestHostServices()
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.transcribe(
                audio: Self.audio(),
                language: nil,
                translate: false,
                prompt: nil
            )
            XCTFail("Expected notConfigured")
        } catch let error as PluginTranscriptionError {
            guard case .notConfigured = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTranscribeRejectsTranslateRequests() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        do {
            _ = try await plugin.transcribe(
                audio: Self.audio(),
                language: nil,
                translate: true,
                prompt: nil
            )
            XCTFail("Expected apiError")
        } catch let error as PluginTranscriptionError {
            guard case .apiError(let message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "OpenRouter speech-to-text does not support translation.")
        }
    }

    func testTranscriptionRequestUsesJSONBase64AndLanguage() throws {
        let request = try OpenRouterPlugin.makeTranscriptionRequest(
            uploadFile: Self.m4aUpload(),
            apiKey: "openrouter-key",
            modelId: "openai/whisper-1",
            language: " de ",
            timeout: 120
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer openrouter-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 120)

        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["model"] as? String, "openai/whisper-1")
        XCTAssertEqual(body["language"] as? String, "de")
        XCTAssertEqual(body["response_format"] as? String, "verbose_json")
        XCTAssertEqual(body["timestamp_granularities"] as? [String], ["segment"])

        let inputAudio = try XCTUnwrap(body["input_audio"] as? [String: Any])
        XCTAssertEqual(inputAudio["format"] as? String, "m4a")
        XCTAssertEqual(inputAudio["data"] as? String, Data("m4a".utf8).base64EncodedString())
    }

    func testTranscriptionRequestOmitsEmptyLanguageAndPrompt() throws {
        let request = try OpenRouterPlugin.makeTranscriptionRequest(
            uploadFile: Self.m4aUpload(),
            apiKey: "openrouter-key",
            modelId: "openai/whisper-1",
            language: " ",
            timeout: 120
        )

        let body = try Self.jsonBody(from: request)
        XCTAssertNil(body["language"])
        XCTAssertNil(body["prompt"])
    }

    func testTranscriptionRequestUsesPlainJSONForUnsupportedTimestampProvider() throws {
        let request = try OpenRouterPlugin.makeTranscriptionRequest(
            uploadFile: Self.m4aUpload(),
            apiKey: "openrouter-key",
            modelId: "deepgram/nova-3",
            language: nil,
            timeout: 120
        )

        let body = try Self.jsonBody(from: request)
        XCTAssertNil(body["response_format"])
        XCTAssertNil(body["timestamp_granularities"])
    }

    func testTranscriptionRequestUsesVerboseJSONForCompatibleTimestampProviders() throws {
        for modelId in [
            "openai/whisper-1",
            "groq/whisper-large-v3",
            "together/whisper-large-v3",
        ] {
            let request = try OpenRouterPlugin.makeTranscriptionRequest(
                uploadFile: Self.m4aUpload(),
                apiKey: "openrouter-key",
                modelId: modelId,
                language: nil,
                timeout: 120
            )

            let body = try Self.jsonBody(from: request)
            XCTAssertEqual(body["response_format"] as? String, "verbose_json", modelId)
            XCTAssertEqual(body["timestamp_granularities"] as? [String], ["segment"], modelId)
        }
    }

    func testTranscribeRequestsAndParsesTimedSegments() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "openai/whisper-1"],
            secrets: ["api-key": "openrouter-key"]
        )
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(
                        #"{"text":"hello from openrouter","language":"en","segments":[{"id":0,"start":0.0,"end":1.25,"text":"hello from"},{"id":1,"start":1.25,"end":2.5,"text":"openrouter"}],"usage":{"cost":0.01}}"#.utf8
                    ),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: Self.audio(),
            language: "de",
            translate: false,
            prompt: "ignored dictionary terms"
        )

        XCTAssertEqual(result.text, "hello from openrouter")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.segments.count, 2)
        XCTAssertEqual(result.segments[0].text, "hello from")
        XCTAssertEqual(result.segments[0].start, 0.0)
        XCTAssertEqual(result.segments[0].end, 1.25)
        XCTAssertEqual(result.segments[1].text, "openrouter")
        XCTAssertEqual(result.segments[1].start, 1.25)
        XCTAssertEqual(result.segments[1].end, 2.5)

        let request = try XCTUnwrap(store.sessions.first?.requestedRequests.first)
        XCTAssertEqual(request.url?.path, "/api/v1/audio/transcriptions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try Self.jsonBody(from: request)
        XCTAssertEqual(body["model"] as? String, "openai/whisper-1")
        XCTAssertEqual(body["language"] as? String, "de")
        XCTAssertNil(body["prompt"])
        XCTAssertEqual(body["response_format"] as? String, "verbose_json")
        XCTAssertEqual(body["timestamp_granularities"] as? [String], ["segment"])
        let inputAudio = try XCTUnwrap(body["input_audio"] as? [String: Any])
        XCTAssertEqual(inputAudio["format"] as? String, "m4a")
    }

    func testMAITranscribe2SendsWavOnFirstRequest() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)
        plugin.selectModel("microsoft/mai-transcribe-2")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"text":"MAI transcript"}"#.utf8),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let audio = Self.audio()
        let result = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: nil)

        XCTAssertEqual(result.text, "MAI transcript")
        let requests = store.sessions.flatMap(\.requestedRequests)
        XCTAssertEqual(requests.count, 1)
        let body = try Self.jsonBody(from: XCTUnwrap(requests.first))
        XCTAssertEqual(body["model"] as? String, "microsoft/mai-transcribe-2")
        XCTAssertEqual(body["language"] as? String, "en")
        let inputAudio = try XCTUnwrap(body["input_audio"] as? [String: Any])
        XCTAssertEqual(inputAudio["format"] as? String, "wav")
        let encodedAudio = try XCTUnwrap(inputAudio["data"] as? String)
        XCTAssertEqual(Data(base64Encoded: encodedAudio), PluginAudioUploadEncoder.wavUpload(from: audio).data)
    }

    func testChunkLengthKeepsEveryRequestWithinTheUpstreamTimeout() {
        XCTAssertEqual(OpenRouterPlugin.maximumChunkDuration(modelId: "openai/whisper-1"), 300)
        XCTAssertEqual(OpenRouterPlugin.maximumChunkDuration(modelId: "openai/gpt-4o-transcribe"), 300)
        XCTAssertEqual(OpenRouterPlugin.maximumChunkDuration(modelId: "microsoft/mai-transcribe-2"), 300)
        XCTAssertEqual(OpenRouterPlugin.maximumChunkDuration(modelId: "example/new-transcription-model"), 300)
        XCTAssertEqual(OpenRouterPlugin.maximumChunkDuration(modelId: "fish-audio/transcribe-1-pro"), 300)
    }

    func testChunkLengthStaysBelowShorterProviderLimits() {
        XCTAssertEqual(OpenRouterPlugin.maximumChunkDuration(modelId: "google/chirp-3"), 55)
        XCTAssertEqual(OpenRouterPlugin.maximumChunkDuration(modelId: "assemblyai/universal-3-5-pro"), 115)
        XCTAssertEqual(OpenRouterPlugin.maximumChunkDuration(modelId: "fish-audio/transcribe-1"), 180)
        XCTAssertEqual(OpenRouterPlugin.maximumChunkDuration(modelId: "qwen/qwen3-asr-flash-2026-02-10"), 230)
    }

    func testAssemblyAISplitsRecordingsLongerThanItsSyncLimit() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)
        plugin.selectModel("assemblyai/universal-3-5-pro")

        let url = "https://openrouter.ai/api/v1/audio/transcriptions"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: ["first", "second", "third"].map { text in
                .success(Data(#"{"text":"\#(text)"}"#.utf8), Self.httpResponse(url: url, statusCode: 200))
            })
        }

        // Four minutes: three chunks below AssemblyAI's 120 seconds.
        let samples = [Float](repeating: 0.3, count: 16_000 * 240)
        let audio = AudioData(samples: samples, wavData: Data(), duration: 240)
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "first second third")
        XCTAssertEqual(store.sessions.flatMap(\.requestedRequests).count, 3)
    }

    /// 来自实机保存的 OpenRouter 模型接口响应（/tmp/dictum-p6-live/c9/openrouter-models.json），只留原文条目。
    private static let sampleModelsResponse = """
    {
      "data": [
        {
          "id": "moonshotai/kimi-k3.1-pro",
          "name": "MoonshotAI: Kimi K3.1 Pro",
          "pricing": { "prompt": "0.000002", "completion": "0.00001" },
          "architecture": { "modality": "text+image+video->text" }
        },
        {
          "id": "google/gemini-nano-banana-2.1",
          "name": "Google: Nano Banana 2.1",
          "pricing": { "prompt": "0.0000005", "completion": "0.0000015" },
          "architecture": { "modality": "text+image->text+image" }
        },
        {
          "id": "recursive/flint-v1.0:free",
          "name": "Recursive: Flint (free)",
          "pricing": { "prompt": "0", "completion": "0" },
          "architecture": { "modality": "text->text" }
        },
        {
          "id": "nvidia/nemotron-3-ultra-550b-a55b:free",
          "name": "NVIDIA: Nemotron 3 Ultra (free)",
          "pricing": { "prompt": "0", "completion": "0" },
          "architecture": { "modality": "text->text" }
        },
        {
          "id": "google/gemma-4-26b-a4b-it:free",
          "name": "Google: Gemma 4 26B A4B  (free)",
          "pricing": { "prompt": "0", "completion": "0" },
          "architecture": { "modality": "text+image+video->text" }
        },
        {
          "id": "liquid/lfm-2.5-2.6b:free",
          "name": "LiquidAI: LFM2.5-2.6B (free)",
          "pricing": { "prompt": "0", "completion": "0" },
          "architecture": { "modality": "text->text" }
        },
        {
          "id": "deepseek/deepseek-v4.1-flash-1017",
          "name": "DeepSeek: DeepSeek V4.1 Flash 1017",
          "pricing": { "prompt": "0.00000015", "completion": "0.0000006" },
          "architecture": { "modality": "text+image->text" }
        }
      ]
    }
    """

    func testFetchLLMModelsParsesSavedAPIResponse() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(Self.sampleModelsResponse.utf8),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/models", statusCode: 200)
                ),
            ])
        }

        let models = await plugin.fetchLLMModels()

        XCTAssertEqual(models.map(\.id), [
            "deepseek/deepseek-v4.1-flash-1017",
            "google/gemma-4-26b-a4b-it:free",
            "liquid/lfm-2.5-2.6b:free",
            "moonshotai/kimi-k3.1-pro",
            "nvidia/nemotron-3-ultra-550b-a55b:free",
            "recursive/flint-v1.0:free",
        ])
        XCTAssertEqual(models.first { $0.id == "moonshotai/kimi-k3.1-pro" }?.promptPrice, "0.000002")
        XCTAssertTrue(models.contains { $0.id.hasSuffix(":free") })
    }

    /// AI 模型页通过这个选择子刷新菜单，刷新后菜单列出接口返回的全部文本模型（含 :free）。
    func testLLMModelMenuRefreshSelectorFetchesAPIList() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(Self.sampleModelsResponse.utf8),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/models", statusCode: 200)
                ),
            ])
        }

        let selector = NSSelectorFromString("dictumRefreshLLMModels")
        XCTAssertTrue(plugin.responds(to: selector))
        _ = plugin.perform(selector)

        for _ in 0..<200 where plugin.supportedModels.count < 6 {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertEqual(plugin.supportedModels.map(\.id), [
            "deepseek/deepseek-v4.1-flash-1017",
            "google/gemma-4-26b-a4b-it:free",
            "liquid/lfm-2.5-2.6b:free",
            "moonshotai/kimi-k3.1-pro",
            "nvidia/nemotron-3-ultra-550b-a55b:free",
            "recursive/flint-v1.0:free",
        ])
        XCTAssertNotNil(host.userDefault(forKey: "fetchedModels") as? Data)
    }

    /// 所有者没有选过模型时，菜单显示和处理使用的默认是免费模型。
    func testDefaultLLMModelIsFreeWhenNothingSelected() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        let selectable = try XCTUnwrap(plugin as? LLMModelSelectable)
        let defaultModelId = try XCTUnwrap(selectable.defaultModelId ?? nil)
        XCTAssertTrue(defaultModelId.hasSuffix(":free"))
        XCTAssertEqual(plugin.selectedLLMModelId, defaultModelId)
        XCTAssertTrue((plugin.selectedLLMModelId ?? "").hasSuffix(":free"))
    }

    /// 已拉取的模型列表里，默认取排序后第一个免费模型。
    func testDefaultLLMModelPicksFirstFreeFromFetchedList() throws {
        let fetched = try JSONEncoder().encode([
            OpenRouterFetchedModel(
                id: "moonshotai/kimi-k3.1-pro", name: "MoonshotAI: Kimi K3.1 Pro",
                promptPrice: "0.000002", completionPrice: "0.00001"
            ),
            OpenRouterFetchedModel(
                id: "google/gemma-4-26b-a4b-it:free", name: "Google: Gemma 4 26B A4B (free)",
                promptPrice: "0", completionPrice: "0"
            ),
            OpenRouterFetchedModel(
                id: "deepseek/deepseek-v4.1-flash-1017", name: "DeepSeek: DeepSeek V4.1 Flash 1017",
                promptPrice: "0.00000015", completionPrice: "0.0000006"
            ),
        ])
        let host = try PluginTestHostServices(defaults: ["fetchedModels": fetched])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        XCTAssertEqual(plugin.supportedModels.map(\.id), [
            "moonshotai/kimi-k3.1-pro", "google/gemma-4-26b-a4b-it:free", "deepseek/deepseek-v4.1-flash-1017",
        ])
        XCTAssertEqual(plugin.selectedLLMModelId, "google/gemma-4-26b-a4b-it:free")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "google/gemma-4-26b-a4b-it:free")
    }

    /// 旧设置视图的刷新路径：手输的自定义模型 ID 不在接口列表里，刷新后仍保持选中。
    @MainActor
    func testSettingsViewApplyKeepsTypedCustomLLMModelId() throws {
        let host = try PluginTestHostServices()
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)
        plugin.dictumSelectLLMModel("myco/test-model-1")

        let view = OpenRouterSettingsView(plugin: plugin)
        view.applyLLMModels([
            OpenRouterFetchedModel(
                id: "a-vendor/paid-model", name: "A Vendor Paid",
                promptPrice: "0.000003", completionPrice: "0.00003"
            ),
            OpenRouterFetchedModel(
                id: "z-vendor/free-model:free", name: "Z Vendor Free",
                promptPrice: "0", completionPrice: "0"
            ),
        ])

        XCTAssertEqual(plugin.selectedLLMModelId, "myco/test-model-1")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "myco/test-model-1")
    }

    /// 旧设置视图的刷新路径：已选模型被接口下架后回落到列表里第一个免费模型。
    @MainActor
    func testSettingsViewApplyFallsBackToFirstFreeModelWhenSavedModelDelisted() throws {
        let storedFetched = try JSONEncoder().encode([
            OpenRouterFetchedModel(
                id: "vendor/delisted-model", name: "Vendor Delisted",
                promptPrice: "0.000001", completionPrice: "0.000001"
            ),
        ])
        let host = try PluginTestHostServices(defaults: [
            "fetchedModels": storedFetched,
            "selectedLLMModel": "vendor/delisted-model",
        ])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)
        XCTAssertEqual(plugin.selectedLLMModelId, "vendor/delisted-model")

        let view = OpenRouterSettingsView(plugin: plugin)
        view.applyLLMModels([
            OpenRouterFetchedModel(
                id: "a-vendor/paid-model", name: "A Vendor Paid",
                promptPrice: "0.000003", completionPrice: "0.00003"
            ),
            OpenRouterFetchedModel(
                id: "z-vendor/free-model:free", name: "Z Vendor Free",
                promptPrice: "0", completionPrice: "0"
            ),
        ])

        XCTAssertEqual(plugin.selectedLLMModelId, "z-vendor/free-model:free")
        XCTAssertEqual(host.userDefault(forKey: "selectedLLMModel") as? String, "z-vendor/free-model:free")
    }

    /// 旧设置视图的刷新路径：转写模型被接口下架后已保存的选择保持不变。
    @MainActor
    func testSettingsViewApplyKeepsDelistedTranscriptionModel() throws {
        let storedFetched = try JSONEncoder().encode([
            OpenRouterFetchedModel(
                id: "vendor/delisted-stt", name: "Vendor Delisted STT",
                promptPrice: "0.000006", completionPrice: "0"
            ),
        ])
        let host = try PluginTestHostServices(defaults: [
            "fetchedTranscriptionModels": storedFetched,
            "selectedModel": "vendor/delisted-stt",
        ])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)
        XCTAssertEqual(plugin.selectedModelId, "vendor/delisted-stt")

        let view = OpenRouterSettingsView(plugin: plugin)
        view.applyTranscriptionModels([
            OpenRouterFetchedModel(
                id: "a-vendor/new-stt", name: "A Vendor STT",
                promptPrice: "0.000002", completionPrice: "0"
            ),
            OpenRouterFetchedModel(
                id: "z-vendor/other-stt", name: "Z Vendor STT",
                promptPrice: "0.000004", completionPrice: "0"
            ),
        ])

        XCTAssertEqual(plugin.selectedModelId, "vendor/delisted-stt")
        XCTAssertEqual(host.userDefault(forKey: "selectedModel") as? String, "vendor/delisted-stt")
    }

    func testTranscribeSplitsLongRecordingsIntoFiveMinuteRequests() async throws {
        // A request that outlasts the provider's 60 s or an oversized body ends in
        // a 5xx or a lost connection, not in a 413 (#1538).
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "openai/whisper-1"],
            secrets: ["api-key": "openrouter-key"]
        )
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        let url = "https://openrouter.ai/api/v1/audio/transcriptions"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: ["first", "second", "third"].map { text in
                .success(
                    Data(#"{"text":" \#(text) ","language":"en","segments":[{"start":0.5,"end":1.5,"text":"\#(text)"}]}"#.utf8),
                    Self.httpResponse(url: url, statusCode: 200)
                )
            })
        }

        // Eleven minutes, three chunks.
        let samples = [Float](repeating: 0.3, count: 16_000 * 660)
        let audio = AudioData(samples: samples, wavData: Data(), duration: 660)
        let result = try await plugin.transcribe(audio: audio, language: "en", translate: false, prompt: nil)

        XCTAssertEqual(result.text, "first second third")
        XCTAssertEqual(result.detectedLanguage, "en")
        XCTAssertEqual(result.segments.map(\.text), ["first", "second", "third"])
        let starts = result.segments.map(\.start)
        XCTAssertEqual(starts[0], 0.5, accuracy: 0.0001)
        XCTAssertTrue(zip(starts, starts.dropFirst()).allSatisfy { $0 + 200 < $1 }, "\(starts)")

        let requests = store.sessions.flatMap(\.requestedRequests)
        XCTAssertEqual(requests.count, 3)
        for request in requests {
            let body = try Self.jsonBody(from: request)
            XCTAssertEqual(body["model"] as? String, "openai/whisper-1")
            XCTAssertEqual(body["language"] as? String, "en")
            let inputAudio = try XCTUnwrap(body["input_audio"] as? [String: Any])
            XCTAssertEqual(inputAudio["format"] as? String, "m4a")
            let audioData = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(inputAudio["data"] as? String)))
            XCTAssertLessThan(audioData.count, 25 * 1_024 * 1_024)
        }
    }

    func testMAITranscribe2SplitsLongRecordingsIntoWavChunks() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)
        plugin.selectModel("microsoft/mai-transcribe-2")

        let url = "https://openrouter.ai/api/v1/audio/transcriptions"
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(Data(#"{"text":"first"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
                .success(Data(#"{"text":"second"}"#.utf8), Self.httpResponse(url: url, statusCode: 200)),
            ])
        }

        // Six minutes: one request before, two now.
        let samples = [Float](repeating: 0.3, count: 16_000 * 360)
        let audio = AudioData(samples: samples, wavData: Data(), duration: 360)
        let result = try await plugin.transcribe(audio: audio, language: nil, translate: false, prompt: nil)

        XCTAssertEqual(result.text, "first second")
        let requests = store.sessions.flatMap(\.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        let uploadedAudio = try requests.map { request -> Data in
            let body = try Self.jsonBody(from: request)
            let inputAudio = try XCTUnwrap(body["input_audio"] as? [String: Any])
            XCTAssertEqual(inputAudio["format"] as? String, "wav")
            return try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(inputAudio["data"] as? String)))
        }
        // Each chunk carries only its own samples, as 16-bit WAV with a 44-byte header.
        XCTAssertEqual(uploadedAudio.map(\.count).reduce(0, +), samples.count * 2 + 2 * 44)
        XCTAssertTrue(uploadedAudio.allSatisfy { $0.count < 25 * 1_024 * 1_024 })
    }

    func testPayloadTooLargeFailsWithoutRetry() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)
        plugin.selectModel("microsoft/mai-transcribe-2")

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [.success(
                Data(),
                Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 413)
            )])
        }

        do {
            _ = try await plugin.transcribe(audio: Self.audio(), language: nil, translate: false, prompt: nil)
            XCTFail("Expected fileTooLarge")
        } catch PluginTranscriptionError.fileTooLarge {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(store.sessions.flatMap(\.requestedRequests).count, 1)
    }

    func testTranscribeRetriesWithWavWhenM4AIsRejected() async throws {
        let host = try PluginTestHostServices(
            defaults: ["selectedModel": "openai/whisper-1"],
            secrets: ["api-key": "openrouter-key"]
        )
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)

        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"unsupported audio format"}}"#.utf8),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 415)
                ),
                .success(
                    Data(#"{"text":"fallback transcript"}"#.utf8),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.transcribe(
            audio: Self.audio(),
            language: "de",
            translate: false,
            prompt: nil
        )

        XCTAssertEqual(result.text, "fallback transcript")
        let requests = store.sessions[0].requestedRequests
        XCTAssertEqual(requests.count, 2)
        let firstBody = try Self.jsonBody(from: requests[0])
        let firstAudio = try XCTUnwrap(firstBody["input_audio"] as? [String: Any])
        XCTAssertEqual(firstAudio["format"] as? String, "m4a")
        let retryBody = try Self.jsonBody(from: requests[1])
        let retryAudio = try XCTUnwrap(retryBody["input_audio"] as? [String: Any])
        XCTAssertEqual(retryAudio["format"] as? String, "wav")
        XCTAssertEqual(retryBody["model"] as? String, "openai/whisper-1")
        XCTAssertEqual(retryBody["language"] as? String, "de")
    }

    func testGenericProvider400RetriesOtherModelsWithWav() async throws {
        let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
        let plugin = OpenRouterPlugin()
        plugin.activate(host: host)
        plugin.selectModel("example/new-transcription-model")
        let store = PluginHTTPClientSessionStore()
        PluginHTTPClientTestHarness.configure { _ in
            store.makeSession(outcomes: [
                .success(
                    Data(#"{"error":{"message":"Provider returned 400","code":400}}"#.utf8),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 400)
                ),
                .success(
                    Data(#"{"text":"recovered transcript"}"#.utf8),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 200)
                ),
            ])
        }

        let result = try await plugin.transcribe(audio: Self.audio(), language: "de", translate: false, prompt: nil)
        XCTAssertEqual(result.text, "recovered transcript")
        let requests = store.sessions.flatMap(\.requestedRequests)
        XCTAssertEqual(requests.count, 2)
        for (index, request) in requests.enumerated() {
            let body = try Self.jsonBody(from: request)
            XCTAssertEqual(body["model"] as? String, "example/new-transcription-model")
            XCTAssertEqual(body["language"] as? String, "de")
            let audio = try XCTUnwrap(body["input_audio"] as? [String: Any])
            XCTAssertEqual(audio["format"] as? String, index == 0 ? "m4a" : "wav")
        }
    }

    func testGenericProvider400DoesNotRetryWavAgain() async throws {
        for model in ["example/new-transcription-model", "microsoft/mai-transcribe-2"] {
            PluginHTTPClientTestHarness.reset()
            let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
            let plugin = OpenRouterPlugin()
            plugin.activate(host: host)
            plugin.selectModel(model)
            let store = PluginHTTPClientSessionStore()
            PluginHTTPClientTestHarness.configure { _ in
                store.makeSession(outcomes: Array(repeating: .success(
                    Data(#"{"error":{"message":"Provider returned 400","code":400}}"#.utf8),
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 400)
                ), count: 3))
            }
            do {
                _ = try await plugin.transcribe(audio: Self.audio(), language: nil, translate: false, prompt: nil)
                XCTFail("Expected provider error")
            } catch {
                guard case PluginTranscriptionError.apiError(let message) = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
                XCTAssertEqual(message, "HTTP 400: Provider returned 400")
            }
            XCTAssertEqual(store.sessions.flatMap(\.requestedRequests).count, model == "microsoft/mai-transcribe-2" ? 1 : 2)
        }
    }

    func testExplicitRequestErrorsDoNotTriggerWavRetry() async throws {
        for (status, message) in [(400, "Model not found"), (401, "Invalid API key"), (403, "Forbidden"), (429, "Rate limited")] {
            PluginHTTPClientTestHarness.reset()
            let host = try PluginTestHostServices(secrets: ["api-key": "openrouter-key"])
            let plugin = OpenRouterPlugin()
            plugin.activate(host: host)
            let store = PluginHTTPClientSessionStore()
            let responseData = try JSONSerialization.data(withJSONObject: ["error": ["message": message]])
            PluginHTTPClientTestHarness.configure { _ in
                store.makeSession(outcomes: [.success(
                    responseData,
                    Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: status)
                )])
            }
            do {
                _ = try await plugin.transcribe(audio: Self.audio(), language: nil, translate: false, prompt: nil)
                XCTFail("Expected HTTP \(status)")
            } catch {
                XCTAssertTrue(error is PluginTranscriptionError)
            }
            XCTAssertEqual(store.sessions.flatMap(\.requestedRequests).count, 1, "HTTP \(status)")
        }
    }

    func testTranscriptionHTTPErrorMapping() {
        XCTAssertThrowsError(try OpenRouterPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"bad key"}}"#.utf8),
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 401)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .invalidApiKey = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try OpenRouterPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"slow down"}}"#.utf8),
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 429)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .rateLimited = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertThrowsError(try OpenRouterPlugin.validateTranscriptionResponse(
            data: Data(#"{"error":{"message":"server failed"}}"#.utf8),
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 500)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .apiError(let message) = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(message, "HTTP 500: server failed")
        }
    }

    func testTranscriptionRejectsHTMLSuccessBody() {
        let data = Data("<html><head><title>Proxy failure</title></head><body>secret</body></html>".utf8)

        XCTAssertThrowsError(try OpenRouterPlugin.validateTranscriptionResponse(
            data: data,
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 200)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .apiError(let message) = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("upstream returned an HTML error page"))
            XCTAssertTrue(message.contains("Proxy failure"))
            XCTAssertFalse(message.contains("secret"))
        }
    }

    func testTranscriptionBoundsExtractedJSONErrorMessage() {
        let providerMessage = String(repeating: "x", count: 700)
        let data = Data("{\"error\":{\"message\":\"\(providerMessage)\"}}".utf8)

        XCTAssertThrowsError(try OpenRouterPlugin.validateTranscriptionResponse(
            data: data,
            response: Self.httpResponse(url: "https://openrouter.ai/api/v1/audio/transcriptions", statusCode: 500)
        )) { error in
            guard let pluginError = error as? PluginTranscriptionError,
                  case .apiError(let message) = pluginError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.hasSuffix("(truncated from 700 bytes)"))
            XCTAssertLessThan(message.count, 580)
        }
    }

    private static func audio() -> AudioData {
        audio(duration: 1)
    }

    private static func audio(duration: TimeInterval) -> AudioData {
        let samples = [Float](repeating: 0.1, count: Int(16_000 * duration))
        return AudioData(samples: samples, wavData: PluginWavEncoder.encode(samples), duration: duration)
    }

    private static func m4aUpload() -> PluginAudioUploadFile {
        PluginAudioUploadFile(
            data: Data("m4a".utf8),
            filename: "audio.m4a",
            contentType: "audio/mp4",
            format: "m4a"
        )
    }

    private static func jsonBody(from request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func httpResponse(url: String, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: url)!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
