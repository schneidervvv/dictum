import Foundation

/// 侧栏进入设置时记住当前所在的主页面，设置里点返回时回到那里。
struct SettingsReturnPage: Equatable {
    private(set) var page: DictumPage = .home

    mutating func pageChanged(from previous: DictumPage, to current: DictumPage) {
        if current.isSettings, !previous.isSettings { page = previous }
    }
}
