import XCTest
@testable import TypeWhisper

/// 已取消的历史记录：同步、导出和设置备份带上可选的取消字段，旧记录按未取消读取；首页统计和最近记录不包含它。
@MainActor
final class CancelledRecordStorageTests: XCTestCase {
    private var directory: URL!
    private var history: HistoryService!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-cancelled-record")
        history = HistoryService(appSupportDirectory: directory, eventEmitter: { _ in })
    }

    override func tearDown() {
        history = nil
        TestSupport.remove(directory)
        super.tearDown()
    }

    @discardableResult
    private func add(
        to history: HistoryService, cancelled: Bool, text: String = "Claude Code is ready",
        timestamp: Date = Date(), translation: HistoryTranslationInfo? = nil
    ) -> UUID {
        let id = UUID()
        XCTAssertTrue(history.addRecord(
            id: id, timestamp: timestamp, rawText: text, finalText: text, appName: "Notes", appBundleIdentifier: "com.apple.Notes",
            durationSeconds: 4, language: "en", engineUsed: "Qwen3-ASR", audioFileName: nil,
            translation: translation, cancelled: cancelled))
        return id
    }

    func testCancelledFlagIsStoredAndOtherRecordsReadAsNotCancelled() throws {
        let cancelled = add(to: history, cancelled: true)
        let plain = UUID()
        XCTAssertTrue(history.addRecord(id: plain, rawText: "hi", finalText: "Hi.", appName: nil, appBundleIdentifier: nil,
                                        durationSeconds: 2, language: "en", engineUsed: "Qwen3-ASR"))
        XCTAssertTrue(try XCTUnwrap(history.record(withID: cancelled)).isCancelled)
        XCTAssertFalse(try XCTUnwrap(history.record(withID: plain)).isCancelled)
    }

    func testSyncContentCarriesTheCancelledFlagAndOldContentReadsAsNotCancelled() throws {
        let content = UserDataSyncHistoryContentV1(
            recordID: UUID(), createdAt: Date(timeIntervalSince1970: 1_700_000_000), updatedAt: Date(timeIntervalSince1970: 1_700_000_001),
            originDeviceID: "mac-a", originPlatform: "macOS", source: "mac", processingState: "ready",
            rawTranscript: "Claude Code is ready", finalText: "Claude Code is ready", durationSeconds: 4, engineDisplayName: "Qwen3-ASR",
            cancelled: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(UserDataSyncHistoryContentV1.self, from: encoder.encode(content)), content)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(content)) as? [String: Any])
        XCTAssertEqual(legacy["cancelled"] as? Bool, true)
        legacy.removeValue(forKey: "cancelled")
        let old = try decoder.decode(UserDataSyncHistoryContentV1.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.cancelled)
    }

    func testCancelledRecordSurvivesTwoMacSync() async throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-cancelled-sync")
        defer { TestSupport.remove(root) }
        let suiteA = "dictum-cancelled-sync-a-\(UUID().uuidString)"
        let suiteB = "dictum-cancelled-sync-b-\(UUID().uuidString)"
        let defaultsA = try XCTUnwrap(UserDefaults(suiteName: suiteA))
        let defaultsB = try XCTUnwrap(UserDefaults(suiteName: suiteB))
        defer {
            defaultsA.removePersistentDomain(forName: suiteA)
            defaultsB.removePersistentDomain(forName: suiteB)
        }
        struct Mac {
            let history: HistoryService
            let store: TypeWhisperUserDataSyncStore
            var state: CloudFolderSyncState
        }
        func makeMac(_ name: String, defaults: UserDefaults) -> Mac {
            let preferences = HistorySyncPreferences(defaults: defaults)
            preferences.isEnabled = true
            let dir = root.appendingPathComponent(name)
            let history = HistoryService(appSupportDirectory: dir, historySyncPreferences: preferences, eventEmitter: { _ in })
            let store = TypeWhisperUserDataSyncStore(
                dictionaryService: DictionaryService(appSupportDirectory: dir), snippetService: SnippetService(appSupportDirectory: dir),
                historyService: history, historySyncPreferences: preferences, defaults: defaults)
            return Mac(history: history, store: store, state: CloudFolderSyncState(deviceId: name))
        }
        var macA = makeMac("mac-a", defaults: defaultsA)
        var macB = makeMac("mac-b", defaults: defaultsB)
        let folder = root.appendingPathComponent("cloud")
        let cancelled = add(to: macA.history, cancelled: true)
        let plain = add(to: macA.history, cancelled: false, text: "Ready.")
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: macA.store, state: &macA.state)
        _ = try await CloudFolderSyncEngine.sync(folderURL: folder, store: macB.store, state: &macB.state)
        XCTAssertTrue(try XCTUnwrap(macB.history.record(withID: cancelled)).isCancelled)
        XCTAssertFalse(try XCTUnwrap(macB.history.record(withID: plain)).isCancelled)
    }

    func testExportsMarkCancelledRecordsOnly() throws {
        let cancelled = try XCTUnwrap(history.record(withID: add(to: history, cancelled: true)))
        XCTAssertTrue(HistoryExporter.exportMarkdown(cancelled).contains("**Status:** Cancelled"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(HistoryExporter.exportJSON(cancelled).utf8)) as? [String: Any])
        XCTAssertEqual(json["cancelled"] as? Bool, true)

        let plain = try XCTUnwrap(history.record(withID: add(to: history, cancelled: false)))
        XCTAssertFalse(HistoryExporter.exportMarkdown(plain).contains("Cancelled"))
        let plainJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(HistoryExporter.exportJSON(plain).utf8)) as? [String: Any])
        XCTAssertNil(plainJSON["cancelled"])
    }

    func testBackupRoundTripKeepsTheFlagAndLeavesCancelledRecordsOutOfStatistics() async throws {
        let suite = "dictum-cancelled-backup-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        func services(_ dir: URL) -> (WorkflowService, DictionaryService, SnippetService, ProfileService, PromptActionService, PluginManager) {
            (WorkflowService(appSupportDirectory: dir, userDefaults: defaults), DictionaryService(appSupportDirectory: dir),
             SnippetService(appSupportDirectory: dir), ProfileService(appSupportDirectory: dir),
             PromptActionService(appSupportDirectory: dir), PluginManager(appSupportDirectory: dir))
        }
        add(to: history, cancelled: true, timestamp: Date(timeIntervalSince1970: 1_700_000_000))
        let source = services(directory)
        let backup = try SettingsBackupExporter.buildBackup(
            workflowService: source.0, dictionaryService: source.1, snippetService: source.2, profileService: source.3,
            promptActionService: source.4, pluginManager: source.5, historyService: history, userDefaults: defaults)
        XCTAssertEqual(backup.history.first?.cancelled, true)

        let destinationDirectory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-cancelled-backup")
        defer { TestSupport.remove(destinationDirectory) }
        let destination = services(destinationDirectory)
        let destinationHistory = HistoryService(appSupportDirectory: destinationDirectory, eventEmitter: { _ in })
        let statistics = UsageStatisticsService(appSupportDirectory: destinationDirectory)
        let result = await SettingsBackupExporter.importBackup(
            backup, workflowService: destination.0, dictionaryService: destination.1, snippetService: destination.2,
            profileService: destination.3, promptActionService: destination.4, pluginManager: destination.5,
            historyService: destinationHistory, usageStatisticsService: statistics, userDefaults: defaults)
        XCTAssertEqual(result.historyImported, 1)
        XCTAssertEqual(destinationHistory.recentRecords.first?.isCancelled, true)
        XCTAssertFalse(statistics.hasAnyStatistics, "取消的记录不计入统计")

        let encoded = try JSONEncoder().encode(backup.history[0])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "cancelled")
        let old = try JSONDecoder().decode(
            SettingsBackupExporter.HistoryEntryDTO.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(old.cancelled)
    }

    func testStatisticsBackfillSkipsCancelledRecords() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        add(to: history, cancelled: true, text: "one two three four five", timestamp: day)
        add(to: history, cancelled: false, text: "one two", timestamp: day)
        let statistics = UsageStatisticsService(appSupportDirectory: directory)
        statistics.backfillFromHistoryIfNeeded(history.allRecords())
        let summary = statistics.summary(from: nil)
        XCTAssertEqual(summary.words, 2)
        XCTAssertEqual(summary.transcriptionCount, 1)
    }

    func testWordRecountLeavesCancelledRecordsOutOfStatistics() throws {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let cancelled = add(to: history, cancelled: true, text: "one two three four five", timestamp: day)
        let plain = add(to: history, cancelled: false, text: "one two", timestamp: day)
        try XCTUnwrap(history.record(withID: cancelled)).wordsCount = 1
        try XCTUnwrap(history.record(withID: plain)).wordsCount = 1
        let deltas = try history.recountWords()
        XCTAssertEqual(deltas.values.reduce(0, +), 1, "只有未取消的记录产生变化量")
        history.discardWordCountRecount()
    }

    func testHomeRecentRecordsLeaveCancelledRecordsOut() throws {
        let plain = add(to: history, cancelled: false, text: "Ready.")
        add(to: history, cancelled: true)
        XCTAssertEqual(HomeMetrics.recentRecords(history.recentRecords).map(\.id), [plain])
    }
}
