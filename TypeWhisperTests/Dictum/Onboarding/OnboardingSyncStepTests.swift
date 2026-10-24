import XCTest
@testable import TypeWhisper

@MainActor
final class OnboardingSyncStepTests: XCTestCase {
    private var root: URL!
    private var suite: String!
    private var defaults: UserDefaults!
    private var controllers: [CloudFolderSyncController] = []

    override func setUpWithError() throws {
        root = try TestSupport.makeTemporaryDirectory(prefix: "dictum-onboarding-sync")
        suite = "dictum-onboarding-sync-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        controllers.forEach { $0.deactivate() }
        controllers = []
        defaults.removePersistentDomain(forName: suite)
        TestSupport.remove(root)
    }

    private var iCloudDrive: URL { root.appendingPathComponent("iCloud Drive", isDirectory: true) }
    private var defaultFolder: URL { iCloudDrive.appendingPathComponent("dictum", isDirectory: true) }

    private func makeController() -> CloudFolderSyncController {
        let directory = root.appendingPathComponent("support", isDirectory: true)
        let preferences = HistorySyncPreferences(defaults: defaults)
        let history = HistoryService(appSupportDirectory: directory, historySyncPreferences: preferences, eventEmitter: { _ in })
        let store = TypeWhisperUserDataSyncStore(
            dictionaryService: DictionaryService(appSupportDirectory: directory),
            snippetService: SnippetService(appSupportDirectory: directory),
            historyService: history, historySyncPreferences: preferences, defaults: defaults)
        let controller = CloudFolderSyncController(
            syncStore: store, historyService: history, historySyncPreferences: preferences, defaults: defaults,
            automaticICloudAvailable: false, defaultFolder: defaultFolder)
        controllers.append(controller)
        return controller
    }

    private func makeICloudDriveAvailable() throws {
        try FileManager.default.createDirectory(at: iCloudDrive, withIntermediateDirectories: true)
    }

    func testStepsKeepPracticeNumbersAndPlaceSyncBeforeDone() {
        XCTAssertEqual(
            [OnboardingStep.welcome, OnboardingStep.permissions, OnboardingStep.microphone, OnboardingStep.model,
             OnboardingStep.dictationPractice, OnboardingStep.translationPractice, OnboardingStep.sync, OnboardingStep.done],
            Array(0..<OnboardingStep.count))
        XCTAssertEqual(OnboardingStep.count, 8)
        XCTAssertEqual(OnboardingStep.dictationPractice, 4)
        XCTAssertEqual(OnboardingStep.translationPractice, 5)
        XCTAssertEqual(OnboardingStep.sync, 6)
        XCTAssertEqual(OnboardingStep.done, 7)
    }

    func testAvailableStepOpensWithTheSwitchOnAndContinueTurnsOnSyncToTheDefaultFolder() async throws {
        try makeICloudDriveAvailable()
        let controller = makeController()
        XCTAssertTrue(controller.needsSyncConsent)
        let step = OnboardingSyncStep(controller: controller)
        XCTAssertTrue(step.isAvailable)
        XCTAssertTrue(step.initialSwitch)
        XCTAssertTrue(step.switchEnabled)

        await step.apply(switchOn: true)

        XCTAssertTrue(controller.isHistorySyncOn)
        XCTAssertEqual(controller.mode, .cloudFolder)
        XCTAssertEqual(controller.selectedFolderURL?.standardizedFileURL, defaultFolder.standardizedFileURL)
        XCTAssertTrue(controller.historySyncPreferences?.isEnabled == true)
        XCTAssertFalse(controller.needsSyncConsent)
        XCTAssertEqual(defaults.object(forKey: "dictum.sync.consent") as? Bool, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: defaultFolder.path))
        XCTAssertFalse(makeController().needsSyncConsent)
    }

    func testSwitchingOffAndContinuingLeavesSyncOffAndRecordsTheChoice() async throws {
        try makeICloudDriveAvailable()
        let controller = makeController()
        let step = OnboardingSyncStep(controller: controller)

        await step.apply(switchOn: false)

        XCTAssertFalse(controller.isHistorySyncOn)
        XCTAssertEqual(controller.mode, .off)
        XCTAssertNil(controller.selectedFolderURL)
        XCTAssertFalse(controller.needsSyncConsent)
        XCTAssertEqual(defaults.object(forKey: "dictum.sync.consent") as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultFolder.path))
        let reopened = makeController()
        XCTAssertFalse(reopened.needsSyncConsent)
        XCTAssertFalse(reopened.isHistorySyncOn)
    }

    func testUnavailableICloudDriveShowsTheSwitchOffAndDisabled() async {
        let controller = makeController()
        let step = OnboardingSyncStep(controller: controller)
        XCTAssertFalse(step.isAvailable)
        XCTAssertFalse(step.initialSwitch)
        XCTAssertFalse(step.switchEnabled)

        await step.apply(switchOn: true)

        XCTAssertFalse(controller.isHistorySyncOn)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.needsSyncConsent)
        XCTAssertEqual(defaults.object(forKey: "dictum.sync.consent") as? Bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultFolder.path))
    }

    func testSyncThatIsAlreadyOnShowsTheSwitchOnAndContinueChangesNothing() async throws {
        try makeICloudDriveAvailable()
        let controller = makeController()
        await controller.enableHistorySync()
        let folder = controller.selectedFolderURL
        let step = OnboardingSyncStep(controller: controller)
        XCTAssertTrue(step.isAlreadyOn)
        XCTAssertTrue(step.initialSwitch)
        XCTAssertFalse(step.switchEnabled)

        await step.apply(switchOn: false)
        await step.apply(switchOn: true)

        XCTAssertTrue(controller.isHistorySyncOn)
        XCTAssertEqual(controller.mode, .cloudFolder)
        XCTAssertEqual(controller.selectedFolderURL, folder)
        XCTAssertEqual(defaults.object(forKey: "dictum.sync.consent") as? Bool, true)
    }

    func testCustomFolderChosenInGeneralStaysWhenTheStepTurnsSyncOn() async throws {
        let custom = root.appendingPathComponent("custom-sync", isDirectory: true)
        let controller = makeController()
        await controller.selectCustomFolder(custom)
        await controller.setMode(.off)
        XCTAssertFalse(controller.isHistorySyncOn)
        let step = OnboardingSyncStep(controller: controller)
        XCTAssertTrue(step.isAvailable)
        XCTAssertTrue(step.initialSwitch)

        await step.apply(switchOn: true)

        XCTAssertTrue(controller.isHistorySyncOn)
        XCTAssertEqual(controller.selectedFolderURL?.standardizedFileURL, custom.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultFolder.path))
        XCTAssertEqual(defaults.object(forKey: "dictum.sync.consent") as? Bool, true)
    }

    func testGeneralSwitchActionAndTheStepShareOneState() async throws {
        try makeICloudDriveAvailable()
        let controller = makeController()
        await controller.enableHistorySync()
        XCTAssertTrue(OnboardingSyncStep(controller: controller).isAlreadyOn)
        await controller.setMode(.off)
        XCTAssertFalse(OnboardingSyncStep(controller: controller).isAlreadyOn)
        XCTAssertEqual(controller.isHistorySyncOn, controller.mode != .off)
    }
}
