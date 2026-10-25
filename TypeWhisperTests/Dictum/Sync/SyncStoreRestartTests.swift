import XCTest
@testable import TypeWhisper

/// 本机存储文件被删除或重建为空后的同步：使用真实的存储文件和临时同步文件夹。
@MainActor
final class SyncStoreRestartTests: XCTestCase {
    private struct Mac {
        let directory: URL
        let preferences: HistorySyncPreferences
        let history: HistoryService
        let dictionary: DictionaryService
        let snippets: SnippetService
        let store: TypeWhisperUserDataSyncStore
    }

    private static let historyTexts = [
        "周四下午三点开会。",
        "把预算表发给财务。",
        "Ship the release notes on Friday.",
        "明天上午十点去机场接人。",
        "Kubernetes 集群升级推迟到下周。",
    ]

    private var root: URL!
    private var cloud: URL!
    private var suiteNames: [String] = []

    override func setUp() async throws {
        root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-store-restart")
        cloud = root.appendingPathComponent("cloud", isDirectory: true)
    }

    override func tearDown() async throws {
        for suiteName in suiteNames {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        TestSupport.remove(root)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "dictum-store-restart-\(UUID().uuidString)"
        suiteNames.append(suiteName)
        return try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    private func launchMac(named name: String, defaults: UserDefaults) -> Mac {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        let preferences = HistorySyncPreferences(defaults: defaults)
        preferences.isEnabled = true
        let history = HistoryService(appSupportDirectory: directory, historySyncPreferences: preferences, eventEmitter: { _ in })
        let dictionary = DictionaryService(appSupportDirectory: directory)
        let snippets = SnippetService(appSupportDirectory: directory)
        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: dictionary,
            snippetService: snippets,
            historyService: history,
            historySyncPreferences: preferences,
            defaults: defaults
        )
        return Mac(
            directory: directory,
            preferences: preferences,
            history: history,
            dictionary: dictionary,
            snippets: snippets,
            store: store
        )
    }

    /// 和负责人在应用停止时删除 `<名称>.store`、`-wal`、`-shm` 一样，然后重新启动。
    private func relaunch(_ mac: inout Mac!, named name: String, defaults: UserDefaults, deletingStores storeNames: [String]) throws {
        let directory = mac.directory
        mac = nil
        for storeName in storeNames {
            for suffix in ["", "-wal", "-shm"] {
                let url = directory.appendingPathComponent("\(storeName).store\(suffix)")
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(storeName).store").path))
        }
        mac = launchMac(named: name, defaults: defaults)
    }

    private func addHistory(to mac: Mac) throws -> [UUID: String] {
        var records: [UUID: String] = [:]
        for (index, text) in Self.historyTexts.enumerated() {
            let id = UUID()
            XCTAssertTrue(mac.history.addRecord(
                id: id,
                timestamp: Date(timeIntervalSince1970: 1_790_000_000 + Double(index) * 60),
                rawText: text,
                finalText: text,
                appName: "TextEdit",
                appBundleIdentifier: "com.apple.TextEdit",
                durationSeconds: 3,
                language: "zh",
                engineUsed: "Qwen3-ASR"
            ))
            records[id] = text
        }
        return records
    }

    private func addDictionaryAndSnippets(to mac: Mac) {
        XCTAssertTrue(mac.dictionary.addEntry(type: .term, original: "星河项目"))
        XCTAssertTrue(mac.dictionary.addEntry(type: .term, original: "Kubernetes"))
        XCTAssertTrue(mac.dictionary.addEntry(type: .correction, original: "clawed code", replacement: "Claude Code"))
        mac.snippets.addSnippet(trigger: "项目地址", replacement: "https://example.com/project")
    }

    private func dictionaryPairs(_ mac: Mac) -> [String] {
        mac.dictionary.entries.map { "\($0.original)→\($0.replacement ?? "")" }.sorted()
    }

    private func snippetPairs(_ mac: Mac) -> [String] {
        mac.snippets.snippets.map { "\($0.trigger)→\($0.replacement)" }.sorted()
    }

    private func historyTexts(_ mac: Mac, ids: some Sequence<UUID>) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: ids.compactMap { id in
            mac.history.record(withID: id).map { (id, $0.finalText) }
        })
    }

    private func folderOperations() throws -> [CloudFolderSyncOperation] {
        let operationsURL = CloudFolderSyncEngine.packageURL(for: cloud).appendingPathComponent("ops", isDirectory: true)
        return try CloudFolderSyncEngine.readOperations(from: operationsURL).operations
    }

    private func sync(_ mac: Mac, state: inout CloudFolderSyncState) async throws {
        _ = try await CloudFolderSyncEngine.sync(folderURL: cloud, store: mac.store, state: &state)
    }

    private static let expectedDictionary = ["Kubernetes→", "clawed code→Claude Code", "星河项目→"]
    private static let expectedSnippets = ["项目地址→https://example.com/project"]

    func testDeletedHistoryStoreRestoresEveryRecordWithoutWritingDeletes() async throws {
        let defaults = try makeDefaults()
        var mac: Mac! = launchMac(named: "mac-a", defaults: defaults)
        let records = try addHistory(to: mac)
        var state = CloudFolderSyncState(deviceId: "mac-a")
        try await sync(mac, state: &state)
        XCTAssertEqual(mac.history.recordCount(), records.count)

        try relaunch(&mac, named: "mac-a", defaults: defaults, deletingStores: ["history"])
        XCTAssertEqual(mac.history.recordCount(), 0, "重新启动后历史存储是新建的空文件")
        try await sync(mac, state: &state)

        XCTAssertEqual(mac.history.recordCount(), records.count)
        XCTAssertEqual(historyTexts(mac, ids: records.keys), records)
        XCTAssertEqual(try folderOperations().filter { $0.kind == .delete }.count, 0)

        // 恢复后的下一次同步没有要上传或应用的内容。
        let operationsBefore = try folderOperations().count
        let result = try await CloudFolderSyncEngine.sync(folderURL: cloud, store: mac.store, state: &state)
        XCTAssertEqual(result.operationsWritten, 0)
        XCTAssertEqual(result.mutationsApplied, 0)
        XCTAssertEqual(try folderOperations().count, operationsBefore)
    }

    func testRebuiltDictionaryAndSnippetStoresRestoreEntriesAndAnotherMacKeepsThem() async throws {
        let defaultsA = try makeDefaults()
        let defaultsB = try makeDefaults()
        var macA: Mac! = launchMac(named: "mac-a", defaults: defaultsA)
        let macB = launchMac(named: "mac-b", defaults: defaultsB)
        addDictionaryAndSnippets(to: macA)
        var stateA = CloudFolderSyncState(deviceId: "mac-a")
        var stateB = CloudFolderSyncState(deviceId: "mac-b")
        try await sync(macA, state: &stateA)
        try await sync(macB, state: &stateB)
        XCTAssertEqual(dictionaryPairs(macB), Self.expectedDictionary)
        XCTAssertEqual(snippetPairs(macB), Self.expectedSnippets)

        try relaunch(&macA, named: "mac-a", defaults: defaultsA, deletingStores: ["dictionary", "snippets"])
        XCTAssertTrue(macA.dictionary.entries.isEmpty, "重新启动后词典存储是新建的空文件")
        XCTAssertTrue(macA.snippets.snippets.isEmpty, "重新启动后文本片段存储是新建的空文件")
        try await sync(macA, state: &stateA)

        XCTAssertEqual(dictionaryPairs(macA), Self.expectedDictionary)
        XCTAssertEqual(snippetPairs(macA), Self.expectedSnippets)
        XCTAssertEqual(try folderOperations().filter { $0.kind == .delete }.count, 0)

        try await sync(macB, state: &stateB)
        XCTAssertEqual(dictionaryPairs(macB), Self.expectedDictionary)
        XCTAssertEqual(snippetPairs(macB), Self.expectedSnippets)

        // 一台全新的 Mac 从文件夹得到全部词条。
        let macC = launchMac(named: "mac-c", defaults: try makeDefaults())
        var stateC = CloudFolderSyncState(deviceId: "mac-c")
        try await sync(macC, state: &stateC)
        XCTAssertEqual(dictionaryPairs(macC), Self.expectedDictionary)
        XCTAssertEqual(snippetPairs(macC), Self.expectedSnippets)
    }

    func testOwnerDeleteAllStillReachesTheOtherMac() async throws {
        let defaultsA = try makeDefaults()
        let defaultsB = try makeDefaults()
        let macA = launchMac(named: "mac-a", defaults: defaultsA)
        let macB = launchMac(named: "mac-b", defaults: defaultsB)
        let records = try addHistory(to: macA)
        addDictionaryAndSnippets(to: macA)
        var stateA = CloudFolderSyncState(deviceId: "mac-a")
        var stateB = CloudFolderSyncState(deviceId: "mac-b")
        try await sync(macA, state: &stateA)
        try await sync(macB, state: &stateB)
        XCTAssertEqual(macB.history.recordCount(), records.count)
        XCTAssertEqual(dictionaryPairs(macB), Self.expectedDictionary)

        // 历史页「删除全部历史」、词典页全选删除、逐个删除文本片段。
        XCTAssertTrue(macA.history.clearAll())
        macA.dictionary.deleteEntries(macA.dictionary.entries)
        for snippet in macA.snippets.snippets {
            macA.snippets.deleteSnippet(snippet)
        }
        try await sync(macA, state: &stateA)
        try await sync(macB, state: &stateB)

        XCTAssertEqual(macB.history.recordCount(), 0)
        XCTAssertTrue(macB.dictionary.entries.isEmpty)
        XCTAssertTrue(macB.snippets.snippets.isEmpty)
        XCTAssertEqual(macA.history.recordCount(), 0)
        XCTAssertTrue(macA.dictionary.entries.isEmpty)
    }

    func testTurningSyncOffAndOnImportsTheWholeFolder() async throws {
        let defaults = try makeDefaults()
        var mac: Mac! = launchMac(named: "mac-a", defaults: defaults)
        let records = try addHistory(to: mac)
        addDictionaryAndSnippets(to: mac)
        var controller: CloudFolderSyncController! = CloudFolderSyncController(
            syncStore: mac.store,
            historyService: mac.history,
            historySyncPreferences: mac.preferences,
            defaults: defaults,
            automaticICloudAvailable: false
        )
        await controller.selectCustomFolder(cloud)
        XCTAssertNil(controller.errorMessage)
        XCTAssertNotNil(controller.lastSyncDate)
        controller.deactivate()
        controller = nil

        try relaunch(&mac, named: "mac-a", defaults: defaults, deletingStores: ["history"])

        // 让保存的同步状态认为新文件还是记录中的那一个：内容丢失但创建时间检测不到，
        // 等同于存储被整体清空的情况，重新打开同步必须从文件夹取回全部条目。
        let stateKey = "cloudFolderSync.syncState"
        var savedState = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(defaults.data(forKey: stateKey))) as? [String: Any]
        )
        let storeURL = mac.directory.appendingPathComponent("history.store")
        let createdAt = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: storeURL.path)[.creationDate] as? Date
        )
        var createdAts = savedState["storeCreatedAts"] as? [String: Any] ?? [:]
        createdAts["history"] = createdAt.timeIntervalSince1970
        savedState["storeCreatedAts"] = createdAts
        defaults.set(try JSONSerialization.data(withJSONObject: savedState), forKey: stateKey)

        controller = CloudFolderSyncController(
            syncStore: mac.store,
            historyService: mac.history,
            historySyncPreferences: mac.preferences,
            defaults: defaults,
            automaticICloudAvailable: false
        )
        defer { controller.deactivate() }
        try await XCTUnwrap(controller.initialSyncTask).value
        XCTAssertEqual(controller.mode, .cloudFolder)
        XCTAssertEqual(mac.history.recordCount(), 0, "前提：启动时的同步没有取回历史")

        await controller.setMode(.off)
        await controller.setMode(.cloudFolder)

        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(mac.history.recordCount(), records.count)
        XCTAssertEqual(historyTexts(mac, ids: records.keys), records)
        XCTAssertEqual(dictionaryPairs(mac), Self.expectedDictionary)
        XCTAssertEqual(snippetPairs(mac), Self.expectedSnippets)
        XCTAssertEqual(try folderOperations().filter { $0.kind == .delete }.count, 0)
    }
}
