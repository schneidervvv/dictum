import Foundation

/// 练习听写和练习翻译是真实的听写会话。
/// 离开练习或完成引导时，仍在录音或识别的会话按用户取消处理：
/// 不向任何窗口插入文字，录音保留 3 秒恢复窗口，之后按历史设置存为已取消的记录。
@MainActor
enum OnboardingPracticeSession {
    static func end(_ dictation: DictationViewModel) {
        guard dictation.state == .recording || dictation.state == .processing else { return }
        dictation.cancelFromVoiceBar()
    }
}
