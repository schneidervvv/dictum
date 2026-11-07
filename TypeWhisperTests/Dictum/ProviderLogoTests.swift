import XCTest
import AppKit
@testable import TypeWhisper

@MainActor
final class ProviderLogoTests: XCTestCase {
    private let speechProviders = ["qwen3", "speechAnalyzer", "assemblyai", "deepgram", "elevenlabs",
                                   "gemini", "groq", "openai", "openrouter", "soniox"]
    private let languageModelProviders = ["openai", "claude", "gemini", "openrouter", "groq",
                                          "deepseek", "qwen", "kimi", "zhipu", "siliconflow"]

    func testEveryKnownProviderHasALogoInTheAssetCatalog() throws {
        for id in Set(speechProviders + languageModelProviders) {
            let asset = try XCTUnwrap(ProviderLogo.asset(providerId: id), id)
            XCTAssertNotNil(NSImage(named: "ProviderLogos/\(asset)"), "\(id) → \(asset)")
        }
    }

    private let presets = [
        ["id": "deepseek", "url": "https://api.deepseek.com/v1"],
        ["id": "qwen", "url": "https://dashscope.aliyuncs.com/compatible-mode/v1"],
        ["id": "siliconflow", "url": "https://api.siliconflow.cn/v1"],
    ]

    func testCompatibleBaseURLMatchesPresetByHost() {
        XCTAssertEqual(ProviderLogo.asset(baseURL: "https://api.deepseek.com/v1", presets: presets), "deepseek")
        XCTAssertEqual(ProviderLogo.asset(baseURL: "https://api.deepseek.com/anything/else", presets: presets), "deepseek")
        XCTAssertEqual(ProviderLogo.asset(baseURL: "https://api.siliconflow.cn/v1/", presets: presets), "siliconflow")
    }

    func testCompatibleBaseURLHostMatchingIgnoresCase() {
        XCTAssertEqual(ProviderLogo.asset(baseURL: "https://API.DeepSeek.com/v1", presets: presets), "deepseek")
        XCTAssertEqual(ProviderLogo.asset(baseURL: "HTTPS://DASHSCOPE.ALIYUNCS.COM/compatible-mode/v1", presets: presets), "qwen")
        XCTAssertEqual(
            ProviderLogo.asset(baseURL: "https://api.deepseek.com/v1", presets: [["id": "deepseek", "url": "https://API.DEEPSEEK.COM/v1"]]),
            "deepseek")
    }

    func testCompatibleBaseURLWithoutPresetHostHasNoAsset() {
        XCTAssertNil(ProviderLogo.asset(baseURL: "https://example.com/v1", presets: presets))
        XCTAssertNil(ProviderLogo.asset(baseURL: "https://api.deepseek.com.evil.example/v1", presets: presets))
        XCTAssertNil(ProviderLogo.asset(baseURL: "not a url", presets: presets))
        XCTAssertNil(ProviderLogo.asset(baseURL: "https://api.deepseek.com/v1", presets: []))
    }

    func testPresetWithoutVendorLogoHasNoAsset() {
        XCTAssertNil(ProviderLogo.asset(baseURL: "https://example.com/v1", presets: [["id": "custom-vendor", "url": "https://example.com/v1"]]))
    }

    func testProvidersWithoutVendorLogoHaveNoAsset() {
        XCTAssertNil(ProviderLogo.asset(providerId: "whisper"))
        XCTAssertNil(ProviderLogo.asset(providerId: "unknown-provider"))
    }
}
