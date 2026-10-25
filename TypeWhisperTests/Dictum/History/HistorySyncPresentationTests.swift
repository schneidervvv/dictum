import XCTest
@testable import TypeWhisper

final class HistorySyncPresentationTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    func testICloudDriveFoldersShowTheDriveNameInsteadOfTheFullPath() {
        let folder = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/dictum", isDirectory: true)
        XCTAssertEqual(HistorySyncPresentation.folderDisplay(folder, home: home), "iCloud Drive › dictum")

        let nested = folder.appendingPathComponent("backup", isDirectory: true)
        XCTAssertEqual(HistorySyncPresentation.folderDisplay(nested, home: home), "iCloud Drive › dictum › backup")
        XCTAssertEqual(HistorySyncPresentation.folderDisplay(nil, home: home, dataFolderName: "dictum"), "iCloud Drive › dictum")
    }

    func testTheDataFolderNameSeparatesTheDevelopmentAndReleaseBuilds() {
        XCTAssertEqual(AppConstants.dataFolderName(isDevelopment: true), "dictum-Dev")
        XCTAssertEqual(AppConstants.dataFolderName(isDevelopment: false), "dictum")
        XCTAssertEqual(AppConstants.appSupportDirectoryName, AppConstants.dataFolderName(isDevelopment: AppConstants.isDevelopment))
    }

    @MainActor
    func testTheDefaultSyncFolderFollowsTheDataFolderName() {
        let drive = "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs"
        for isDevelopment in [true, false] {
            let name = AppConstants.dataFolderName(isDevelopment: isDevelopment)
            XCTAssertEqual(CloudFolderSyncController.defaultICloudFolder(named: name, home: home).path, "\(drive)/\(name)")
            XCTAssertEqual(HistorySyncPresentation.folderDisplay(nil, home: home, dataFolderName: name), "iCloud Drive › \(name)")
        }
        XCTAssertEqual(CloudFolderSyncController.defaultICloudFolder.lastPathComponent, AppConstants.appSupportDirectoryName)
        XCTAssertEqual(HistorySyncPresentation.folderDisplay(nil, home: home), "iCloud Drive › \(AppConstants.appSupportDirectoryName)")
    }

    func testOtherFoldersShowAHomeRelativePath() {
        let inHome = home.appendingPathComponent("Documents/dictum-sync", isDirectory: true)
        XCTAssertEqual(HistorySyncPresentation.folderDisplay(inHome, home: home), "~/Documents/dictum-sync")
        XCTAssertEqual(HistorySyncPresentation.folderDisplay(URL(fileURLWithPath: "/Volumes/Backup/dictum"), home: home), "/Volumes/Backup/dictum")
    }
}
