import SwiftUI

/// 供应商标识与资源目录 `ProviderLogos` 中矢量图的唯一对应表，语音识别和 AI 模型两处界面共用。
/// 键为供应商标识的小写形式；没有官方标识的供应商不在表中，界面改用调用方给出的中性符号。
@MainActor
enum ProviderLogo {
    private static let assetByProvider: [String: String] = [
        "openai": "openai", "claude": "anthropic", "gemini": "gemini", "openrouter": "openrouter", "groq": "groq",
        "qwen3": "qwen", "qwen": "qwen", "speechanalyzer": "apple",
        "assemblyai": "assemblyai", "deepgram": "deepgram", "elevenlabs": "elevenlabs", "soniox": "soniox",
        "deepseek": "deepseek", "kimi": "kimi", "zhipu": "zhipu", "siliconflow": "siliconflow",
    ]
    static let languageModelFallbackSymbol = "server.rack"

    static func asset(providerId: String) -> String? {
        if providerId.hasPrefix("openai-compatible") { return compatibleAsset(profileId: providerId) }
        return assetByProvider[providerId.lowercased()]
    }

    /// 兼容接口配置按接口地址的主机名对应到预设供应商，用户自填的地址也能得到正确的标识。
    private static func compatibleAsset(profileId: String) -> String? {
        guard let snapshot = try? ProviderConfiguration.configure(["id": profileId]),
              let host = (snapshot["url"] as? String).flatMap({ URL(string: $0)?.host }) else { return nil }
        let selector = NSSelectorFromString("dictumPresets")
        let presets = ProviderConfiguration.compatiblePlugin?.responds(to: selector) == true
            ? ProviderConfiguration.compatiblePlugin?.perform(selector)?.takeUnretainedValue() as? [[String: String]] ?? [] : []
        return presets.first { URL(string: $0["url"] ?? "")?.host == host }.flatMap { $0["id"] }.flatMap { assetByProvider[$0] }
    }
}

struct ProviderLogoTile: View {
    let asset: String?
    var fallbackSymbol = "waveform"
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size >= 28 ? 7 : 5)
        ZStack {
            shape.fill(DictumTheme.control)
            shape.strokeBorder(DictumTheme.controlBorder, lineWidth: 0.5)
            if let asset {
                Image("ProviderLogos/\(asset)").resizable().scaledToFit().padding(size * 0.24)
            } else {
                Image(systemName: fallbackSymbol).font(.system(size: size * 0.46))
            }
        }
        .foregroundStyle(DictumTheme.textPrimary)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
