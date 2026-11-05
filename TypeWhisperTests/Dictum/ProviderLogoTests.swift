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

    func testProvidersWithoutVendorLogoHaveNoAsset() {
        XCTAssertNil(ProviderLogo.asset(providerId: "whisper"))
        XCTAssertNil(ProviderLogo.asset(providerId: "unknown-provider"))
    }
}
