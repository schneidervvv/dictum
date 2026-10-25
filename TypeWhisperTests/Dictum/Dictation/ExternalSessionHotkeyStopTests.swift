import XCTest
@testable import TypeWhisper

/// 从菜单栏、Raycast 或本机接口开始的会话没有经过快捷键服务；轻按或按住 Fn、Fn + 左 Shift 或备用快捷键都结束它并插入结果，
/// 不开始新会话，也不把听写升级为翻译。
@MainActor
final class ExternalSessionHotkeyStopTests: DictationSessionTestCase {
    private typealias Keys = DictationSessionFixture

    private func pressFn(_ fixture: DictationSessionFixture) throws {
        try fixture.flagsChanged(Keys.fnKey, down: true, flags: .maskSecondaryFn)
        try fixture.flagsChanged(Keys.fnKey, down: false, flags: [])
    }

    private func pressFnAndLeftShift(_ fixture: DictationSessionFixture) throws {
        try fixture.flagsChanged(Keys.fnKey, down: true, flags: .maskSecondaryFn)
        try fixture.flagsChanged(Keys.leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: Keys.deviceLeftShift)
        try fixture.flagsChanged(Keys.leftShift, down: false, flags: .maskSecondaryFn)
        try fixture.flagsChanged(Keys.fnKey, down: false, flags: [])
    }

    /// 按住超过轻按判定的 0.35 秒再松开，即按住说话的按法。
    private func holdFn(_ fixture: DictationSessionFixture, withLeftShift: Bool = false) async throws {
        try fixture.flagsChanged(Keys.fnKey, down: true, flags: .maskSecondaryFn)
        if withLeftShift {
            try fixture.flagsChanged(Keys.leftShift, down: true, flags: [.maskSecondaryFn, .maskShift], device: Keys.deviceLeftShift)
        }
        try await Task.sleep(for: .milliseconds(500))
        if withLeftShift {
            try fixture.flagsChanged(Keys.leftShift, down: false, flags: .maskSecondaryFn)
        }
        try fixture.flagsChanged(Keys.fnKey, down: false, flags: [])
    }

    /// 外接键盘的备用快捷键（右 Option），与 Fn 同在听写槽位。
    private func useBackupKey(_ fixture: DictationSessionFixture) {
        fixture.hotkeys.setHotkeysForTesting(
            [UnifiedHotkey(keyCode: 63, modifierFlags: 0, isFn: true), UnifiedHotkey(keyCode: Keys.rightOption, modifierFlags: 0, isFn: false)],
            for: .hybrid
        )
    }

    private func pressBackupKey(_ fixture: DictationSessionFixture, holding: Bool = false) async throws {
        try fixture.flagsChanged(Keys.rightOption, down: true, flags: .maskAlternate, device: Keys.deviceRightOption)
        if holding { try await Task.sleep(for: .milliseconds(500)) }
        try fixture.flagsChanged(Keys.rightOption, down: false, flags: [])
    }

    /// 结束后不能有排队的新会话开始录音。
    private func assertNoNewSession(_ fixture: DictationSessionFixture) async throws {
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertNotEqual(fixture.model.state, .recording)
        XCTAssertEqual(fixture.engine.transcribeCount, 1)
    }

    func testFnStopsADictationStartedFromTheMenuAndInsertsTheResult() async throws {
        let fixture = try makeFixture()
        fixture.chain.reply = .success("Claude Code is ready.")
        let session = await fixture.startFromAPI(mode: .dictation)
        XCTAssertEqual(fixture.model.state, .recording)

        try pressFn(fixture)
        let snapshot = try await fixture.waitUntilCompleted(session)

        XCTAssertEqual(snapshot?.status, .completed)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Claude Code is ready.")
        try await assertNoNewSession(fixture)
    }

    func testFnAndLeftShiftStopATranslationStartedFromTheMenuAndInsertTheTranslation() async throws {
        let fixture = try makeFixture()
        fixture.chain.reply = .success("準備ができました。")
        let session = await fixture.startFromAPI(mode: .translation)
        XCTAssertEqual(fixture.model.state, .recording)

        try pressFnAndLeftShift(fixture)
        let snapshot = try await fixture.waitUntilCompleted(session)

        XCTAssertEqual(snapshot?.status, .completed)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "準備ができました。")
        XCTAssertEqual(fixture.history.recentRecords.first?.mode, .translation)
        try await assertNoNewSession(fixture)
    }

    func testFnStopsATranslationStartedFromTheMenu() async throws {
        let fixture = try makeFixture()
        fixture.chain.reply = .success("準備ができました。")
        let session = await fixture.startFromAPI(mode: .translation)

        try pressFn(fixture)
        let snapshot = try await fixture.waitUntilCompleted(session)

        XCTAssertEqual(snapshot?.status, .completed)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "準備ができました。")
        try await assertNoNewSession(fixture)
    }

    func testHoldingFnStopsADictationStartedFromTheMenuAndInsertsTheResult() async throws {
        let fixture = try makeFixture()
        fixture.chain.reply = .success("Claude Code is ready.")
        let session = await fixture.startFromAPI(mode: .dictation)

        try await holdFn(fixture)
        let snapshot = try await fixture.waitUntilCompleted(session)

        XCTAssertEqual(snapshot?.status, .completed)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Claude Code is ready.")
        try await assertNoNewSession(fixture)
    }

    func testHoldingFnAndLeftShiftStopsATranslationStartedFromTheMenuAndInsertsTheTranslation() async throws {
        let fixture = try makeFixture()
        fixture.chain.reply = .success("準備ができました。")
        let session = await fixture.startFromAPI(mode: .translation)

        try await holdFn(fixture, withLeftShift: true)
        let snapshot = try await fixture.waitUntilCompleted(session)

        XCTAssertEqual(snapshot?.status, .completed)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "準備ができました。")
        XCTAssertEqual(fixture.history.recentRecords.first?.mode, .translation)
        try await assertNoNewSession(fixture)
    }

    func testBackupKeyStopsADictationStartedFromTheMenuAndInsertsTheResult() async throws {
        let fixture = try makeFixture()
        useBackupKey(fixture)
        fixture.chain.reply = .success("Claude Code is ready.")
        let session = await fixture.startFromAPI(mode: .dictation)

        try await pressBackupKey(fixture)
        let snapshot = try await fixture.waitUntilCompleted(session)

        XCTAssertEqual(snapshot?.status, .completed)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Claude Code is ready.")
        try await assertNoNewSession(fixture)
    }

    func testHoldingTheBackupKeyStopsATranslationStartedFromTheMenuAndInsertsTheTranslation() async throws {
        let fixture = try makeFixture()
        useBackupKey(fixture)
        fixture.chain.reply = .success("準備ができました。")
        let session = await fixture.startFromAPI(mode: .translation)

        try await pressBackupKey(fixture, holding: true)
        let snapshot = try await fixture.waitUntilCompleted(session)

        XCTAssertEqual(snapshot?.status, .completed)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "準備ができました。")
        try await assertNoNewSession(fixture)
    }

    /// Fn 先到达并结束会话，随后的左 Shift 不升级、不开始翻译，与轻按切换的快捷键会话相同。
    func testFnAndLeftShiftStopADictationStartedFromTheMenuWithoutUpgradingIt() async throws {
        let fixture = try makeFixture()
        fixture.chain.reply = .success("Claude Code is ready.")
        let session = await fixture.startFromAPI(mode: .dictation)

        try pressFnAndLeftShift(fixture)
        let snapshot = try await fixture.waitUntilCompleted(session)

        XCTAssertEqual(snapshot?.status, .completed)
        XCTAssertEqual(fixture.pasteboard.string(forType: .string), "Claude Code is ready.")
        XCTAssertEqual(fixture.history.recentRecords.first?.mode, .dictation)
        XCTAssertFalse(fixture.chain.prompts.contains { $0.contains("Translate a speech transcript") })
        try await assertNoNewSession(fixture)
    }
}
