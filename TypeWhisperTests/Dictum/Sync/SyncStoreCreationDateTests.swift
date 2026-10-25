import SwiftData
import XCTest
@testable import TypeWhisper

private enum CreationDateStoreV1 {
    @Model final class Note {
        var text: String
        init(text: String) { self.text = text }
    }
}

private enum CreationDateStoreV2 {
    @Model final class Note {
        var text: String
        var language: String?
        init(text: String, language: String? = nil) {
            self.text = text
            self.language = language
        }
    }
}

@MainActor
final class SyncStoreCreationDateTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try TestSupport.makeTemporaryDirectory(prefix: "dictum-store-date")
    }

    override func tearDown() async throws {
        TestSupport.remove(directory)
    }

    private func openV1() throws -> Date? {
        let (container, context) = try SwiftDataStoreFactory.create(
            for: [CreationDateStoreV1.Note.self], storeName: "notes", in: directory
        )
        context.insert(CreationDateStoreV1.Note(text: "周四开会"))
        try context.save()
        return SwiftDataStoreFactory.storeCreatedAt(of: container)
    }

    private func deleteStoreFiles() throws {
        for suffix in ["", "-wal", "-shm"] {
            let url = directory.appendingPathComponent("notes.store\(suffix)")
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    func testCreationDateStaysAcrossReopenAndMigrationAndChangesWhenTheFileIsRecreated() throws {
        let created = try XCTUnwrap(try openV1())
        XCTAssertEqual(try openV1(), created)

        let (migrated, migratedContext) = try SwiftDataStoreFactory.create(
            for: [CreationDateStoreV2.Note.self], storeName: "notes", in: directory
        )
        XCTAssertEqual(try migratedContext.fetch(FetchDescriptor<CreationDateStoreV2.Note>()).map(\.text), ["周四开会", "周四开会"])
        XCTAssertEqual(SwiftDataStoreFactory.storeCreatedAt(of: migrated), created)

        try deleteStoreFiles()
        Thread.sleep(forTimeInterval: 0.01)
        let recreated = try XCTUnwrap(try openV1())
        XCTAssertGreaterThan(recreated, created)
    }

    func testServicesReportTheirOwnStoreCreationDates() throws {
        let suiteName = "dictum-store-date-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: DictionaryService(appSupportDirectory: directory),
            snippetService: SnippetService(appSupportDirectory: directory),
            historyService: HistoryService(appSupportDirectory: directory, eventEmitter: { _ in }),
            defaults: defaults
        )
        let dates = store.storeCreationDates()
        XCTAssertEqual(Set(dates.keys), [.dictionary, .snippets, .history])
    }

    func testRestartedCollectionsComparesCurrentCreationDateWithTheRecordedOne() {
        let created = Date(timeIntervalSince1970: 1_790_000_000.25)
        let recreated = Date(timeIntervalSince1970: 1_790_000_100.75)

        // 旧版本保存的状态没有创建时间记录，无法判断哪些存储重建过。
        var legacy = CloudFolderSyncState(deviceId: "mac-a", lastSyncAt: created)
        XCTAssertTrue(legacy.restartedCollections(currentDates: [.history: recreated]).isEmpty)

        var synced = CloudFolderSyncState(
            deviceId: "mac-a",
            storeCreatedAts: [
                "history": created.timeIntervalSince1970,
                "dictionary": created.timeIntervalSince1970,
            ]
        )
        XCTAssertEqual(
            synced.restartedCollections(currentDates: [.history: recreated, .dictionary: created]),
            [.history]
        )
        // 记录里没有这个集合的时间时，当前文件按新建处理；读不到创建时间的集合不算。
        XCTAssertEqual(
            synced.restartedCollections(currentDates: [.history: created, .snippets: created]),
            [.snippets]
        )
    }

    func testStoreCreatedAtsSurviveStateEncoding() throws {
        let createdAt = Date(timeIntervalSince1970: 1_790_000_000.483)
        let state = CloudFolderSyncState(
            deviceId: "mac-a",
            storeCreatedAts: ["history": createdAt.timeIntervalSince1970]
        )
        // 与应用保存同步状态相同的编码方式。
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(CloudFolderSyncState.self, from: encoder.encode(state))
        XCTAssertEqual(decoded.storeCreatedAts?["history"], createdAt.timeIntervalSince1970)
        XCTAssertTrue(decoded.restartedCollections(currentDates: [.history: createdAt]).isEmpty)
    }
}
