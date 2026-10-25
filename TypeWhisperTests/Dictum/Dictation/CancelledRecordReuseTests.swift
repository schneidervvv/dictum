import XCTest
@testable import TypeWhisper

/// 已取消的记录没有插入过：复制最近一条、粘贴上一条、最近转写面板、提示词面板和小组件都取用之前插入的那一条；历史仍显示它。
@MainActor
final class CancelledRecordReuseTests: DictationSessionTestCase {
    /// 听写 A 并插入，再听写 B 并按 Esc 取消，等撤销窗口结束、B 保存为已取消的记录。
    private func insertAThenCancelB(_ fixture: DictationSessionFixture) async throws {
        fixture.engine.text = "first dictation"
        fixture.chain.reply = .success("First dictation.")
        let session = await fixture.startFromAPI(mode: .dictation)
        _ = fixture.model.apiStopRecording()
        _ = try await fixture.waitUntilCompleted(session)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "First dictation.")
        fixture.model.dismissActionFeedback()
        try await fixture.wait(upTo: 5) { fixture.model.state == .idle }

        fixture.engine.text = "second dictation"
        _ = await fixture.startFromAPI(mode: .dictation)
        fixture.recoveryStore.append(fixture.samples)
        fixture.model.cancelFromVoiceBar()
        try await fixture.wait(upTo: 8) { fixture.history.recentRecords.contains(where: \.isCancelled) }
        XCTAssertEqual(fixture.history.recentRecords.map(\.finalText), ["second dictation", "First dictation."])
        XCTAssertEqual(fixture.history.recentRecords.first?.isCancelled, true)
        try await fixture.wait(upTo: 2) { fixture.model.state == .idle }
        XCTAssertEqual(fixture.model.state, .idle)
    }

    func testEveryReusePathSkipsACancelledRecord() async throws {
        let fixture = try makeFixture()
        try await insertAThenCancelB(fixture)
        let records = fixture.history.recentRecords

        XCTAssertEqual(fixture.recent.latestEntry(historyRecords: records)?.finalText, "First dictation.", "菜单栏复制最近一条和粘贴上一条")
        XCTAssertEqual(fixture.recent.mergedEntries(historyRecords: records).map(\.finalText), ["First dictation."], "最近转写面板和提示词面板")

        let copyBoard = NSPasteboard.withUniqueName()
        fixture.model.pasteboardProvider = { copyBoard }
        XCTAssertTrue(fixture.model.canCopyLastTranscription)
        fixture.model.copyLastTranscriptionToClipboard()
        XCTAssertEqual(copyBoard.string(forType: .string), "First dictation.", "复制最近一条快捷键")

        fixture.pasteboard.clearContents()
        fixture.model.pasteLastTranscription()
        try await fixture.wait(upTo: 3) { fixture.pasteboard.string(forType: .string) != nil }
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "First dictation.", "粘贴上一条快捷键")

        let widget = WidgetDataService(historyService: fixture.history, usageStatisticsService: UsageStatisticsService(appSupportDirectory: directory))
        XCTAssertEqual(widget.buildWidgetData(records: records).recentHistory.map(\.preview), ["First dictation."], "小组件的最近记录")
    }

    /// 只有一条已取消的记录时，没有可以复制或粘贴的最近一条。
    func testACancelledRecordAloneOffersNothingToReuse() async throws {
        let fixture = try makeFixture()
        _ = await fixture.startFromAPI(mode: .dictation)
        fixture.recoveryStore.append(fixture.samples)
        fixture.model.cancelFromVoiceBar()
        try await fixture.wait(upTo: 8) { !fixture.history.recentRecords.isEmpty }
        XCTAssertEqual(fixture.history.recentRecords.first?.isCancelled, true)

        XCTAssertNil(fixture.recent.latestEntry(historyRecords: fixture.history.recentRecords))
        XCTAssertFalse(fixture.model.canCopyLastTranscription)
    }
}
