import XCTest
@testable import TypeWhisper

/// 旧「高级设置」窗口 Home 页签的最近记录与新首页一致：已取消的记录不出现在最近记录里。
@MainActor
final class HomeViewModelRecentRecordsTests: XCTestCase {
    private func makeHistory(_ directory: URL, cancelledOnly: Bool) throws -> HistoryService {
        let history = HistoryService(appSupportDirectory: directory)
        if !cancelledOnly {
            XCTAssertTrue(history.addRecord(
                rawText: "kept", finalText: "kept", appName: "Notes", appBundleIdentifier: "com.apple.Notes",
                durationSeconds: 1, language: "en", engineUsed: "test-engine"
            ))
        }
        XCTAssertTrue(history.addRecord(
            rawText: "cancelled", finalText: "cancelled", appName: "Notes", appBundleIdentifier: "com.apple.Notes",
            durationSeconds: 1, language: "en", engineUsed: "test-engine", cancelled: true
        ))
        return history
    }

    func testRecentTranscriptionsSkipCancelledRecords() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-home-recent")
        defer { TestSupport.remove(directory) }
        let history = try makeHistory(directory, cancelledOnly: false)
        let model = HomeViewModel(
            historyService: history,
            usageStatisticsService: UsageStatisticsService(appSupportDirectory: directory)
        )
        model.refresh()
        XCTAssertEqual(model.recentTranscriptions.map(\.finalText), ["kept"])
    }

    func testCancelledOnlyHistoryDoesNotCountAsExistingTranscriptions() throws {
        let directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-home-recent")
        defer { TestSupport.remove(directory) }
        let history = try makeHistory(directory, cancelledOnly: true)
        let model = HomeViewModel(
            historyService: history,
            usageStatisticsService: UsageStatisticsService(appSupportDirectory: directory)
        )
        model.refresh()
        XCTAssertTrue(model.recentTranscriptions.isEmpty)
        XCTAssertFalse(model.hasAnyTranscriptions)
    }
}
