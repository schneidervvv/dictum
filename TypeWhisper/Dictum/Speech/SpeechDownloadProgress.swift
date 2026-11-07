import Foundation
import TypeWhisperPluginSDK

struct SpeechDownloadProgress {
    let completedBytes: Int64?
    let totalBytes: Int64?
    let remainingSeconds: Double?
    let bytesPerSecond: Double?

    /// 引擎可以只提供速度（没有字节总量时），也可以只提供字节数；两者都没有时为 nil。
    init?(engine: any TranscriptionEnginePlugin) {
        let selector = NSSelectorFromString("speechDownloadDetails")
        guard let object = engine as? NSObject, object.responds(to: selector),
              let values = object.perform(selector)?.takeUnretainedValue() as? NSDictionary else { return nil }
        let completed = (values["completedBytes"] as? NSNumber)?.int64Value
        let total = (values["totalBytes"] as? NSNumber)?.int64Value
        if let completed, let total, total > 1 {
            completedBytes = completed
            totalBytes = total
        } else {
            completedBytes = nil
            totalBytes = nil
        }
        remainingSeconds = (values["remainingSeconds"] as? NSNumber)?.doubleValue
        bytesPerSecond = (values["bytesPerSecond"] as? NSNumber)?.doubleValue
        guard byteCounts != nil || speedText != nil else { return nil }
    }

    /// 例如 `3.2 MB/s`；没有可用的速度时为 nil。
    var speedText: String? {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    /// 下载失败后按设计显示已下载的大小；失败后插件仍保留字节计数。
    static func interruptedCopy(engine: any TranscriptionEnginePlugin, locale: Locale = .current) -> String {
        let size = ByteCountFormatter.string(fromByteCount: Self(engine: engine)?.completedBytes ?? 0, countStyle: .file)
        return String(localized: LocalizedStringResource("Connection lost, \(size) downloaded", table: "DictumSpeech", locale: locale))
    }

    /// 例如 `2.2 GB / 3.4 GB`；引擎没有提供字节总量时为 nil。
    var byteCounts: String? {
        guard let completedBytes, let totalBytes else { return nil }
        let completed = ByteCountFormatter.string(fromByteCount: completedBytes, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(completed) / \(total)"
    }
}
