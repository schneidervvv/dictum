import XCTest
@testable import TypeWhisper

@MainActor
final class DictionaryAddEntryTests: XCTestCase {
    // 「添加」带「常被听成」的词写入一条纠正记录，词典页显示一行、计数加一。
    func testAddingWordWithHeardAsCreatesOneEntry() throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-add")
        defer { TestSupport.remove(root) }
        let service = DictionaryService(appSupportDirectory: root)
        let before = service.entries.count

        // 词典页「添加」的提交路径
        XCTAssertEqual(try service.addWord("星阙科技", heardAs: ["星雪科技"]), 1)

        let added = service.entries.dropFirst(before)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(added.first?.type, .correction)
        XCTAssertEqual(added.first?.original, "星雪科技")
        XCTAssertEqual(added.first?.replacement, "星阙科技")
        XCTAssertEqual(service.csvItems.filter { $0.word == "星阙科技" }.count, 1)
        XCTAssertEqual(service.applyCorrections(to: "我下周要去星雪科技开会"), "我下周要去星阙科技开会")
    }

    // 同一条「词、常被听成」CSV 行同样只写入一条记录。
    func testCSVImportWithHeardAsColumnCreatesOneEntry() throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-add-import")
        defer { TestSupport.remove(root) }
        let service = DictionaryService(appSupportDirectory: root)
        let before = service.entries.count

        _ = try service.importCSV(Data("星阙科技,星雪科技\n".utf8), format: .default)

        XCTAssertEqual(service.entries.count, before + 1)
        let entry = try XCTUnwrap(service.entries.first { $0.replacement == "星阙科技" })
        XCTAssertEqual(entry.type, .correction)
        XCTAssertEqual(entry.original, "星雪科技")
        XCTAssertEqual(service.csvItems.count, 1)
    }

    // 编辑已有词条原地改写，行数不变。
    func testEditingEntryKeepsOneRow() throws {
        let root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-add-edit")
        defer { TestSupport.remove(root) }
        let service = DictionaryService(appSupportDirectory: root)
        XCTAssertTrue(service.addEntry(type: .correction, original: "星雪科技", replacement: "星阙科技"))
        let entry = try XCTUnwrap(service.entries.first)
        XCTAssertEqual(service.entries.count, 1)

        XCTAssertTrue(service.updateEntry(entry, original: "星雪科技", replacement: "星阙科技公司",
                                          caseSensitive: entry.caseSensitive,
                                          ctcMinSimilarity: entry.ctcMinSimilarity))

        XCTAssertEqual(service.entries.count, 1)
        XCTAssertEqual(service.entries.first?.replacement, "星阙科技公司")
        XCTAssertEqual(service.applyCorrections(to: "星雪科技"), "星阙科技公司")
    }
}
