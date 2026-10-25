import Foundation

/// 菜单状态行在录音中的文字：听写会话写正在听写，翻译会话写正在翻译。
enum MenuBarRecordingStatus {
    static func title(for mode: DictationMode, locale: Locale = .current) -> LocalizedStringResource {
        switch mode {
        case .dictation: LocalizedStringResource("Dictating", table: "DictumHome", locale: locale)
        case .translation: LocalizedStringResource("menu.status.translating", table: "DictumHome", locale: locale)
        }
    }
}
