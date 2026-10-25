import Foundation

/// 同步步骤的开关状态和「继续」时的应用方式；状态都来自通用页共用的同步控制器。
@MainActor
struct OnboardingSyncStep {
    let controller: CloudFolderSyncController

    var isAlreadyOn: Bool { controller.isHistorySyncOn }

    var isAvailable: Bool { isAlreadyOn || controller.canEnableHistorySync }

    var initialSwitch: Bool { isAvailable }

    var switchEnabled: Bool { isAvailable && !isAlreadyOn }

    /// 同步已经开启时不做任何修改；否则按开关开启同步，或记录「暂不开启」。
    func apply(switchOn: Bool) async {
        guard !isAlreadyOn else { return }
        if switchOn && isAvailable {
            await controller.enableHistorySync()
        } else {
            controller.declineDefaultSync()
        }
    }
}
