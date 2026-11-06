import XCTest
@testable import TypeWhisper

final class SettingsReturnPageTests: XCTestCase {
    func testStartsAtHome() {
        XCTAssertEqual(SettingsReturnPage().page, .home)
    }

    func testEnteringSettingsFromAMainPageRemembersThatPage() {
        for main in DictumPage.allCases where !main.isSettings {
            var returnPage = SettingsReturnPage()
            returnPage.pageChanged(from: main, to: .general)
            XCTAssertEqual(returnPage.page, main)
        }
    }

    func testEveryEntryPointIntoSettingsRemembersThePreviousMainPage() {
        for settings in DictumPage.allCases where settings.isSettings {
            var returnPage = SettingsReturnPage()
            returnPage.pageChanged(from: .history, to: settings)
            XCTAssertEqual(returnPage.page, .history, "\(settings)")
        }
    }

    func testMovingBetweenSettingsPagesKeepsTheRememberedPage() {
        var returnPage = SettingsReturnPage()
        returnPage.pageChanged(from: .style, to: .general)
        returnPage.pageChanged(from: .general, to: .speech)
        returnPage.pageChanged(from: .speech, to: .aiModels)
        XCTAssertEqual(returnPage.page, .style)
    }

    func testMovingBetweenMainPagesDoesNotChangeTheRememberedPage() {
        var returnPage = SettingsReturnPage()
        returnPage.pageChanged(from: .dictionary, to: .speech)
        returnPage.pageChanged(from: .speech, to: .history)
        returnPage.pageChanged(from: .history, to: .home)
        XCTAssertEqual(returnPage.page, .dictionary)
    }

    func testEachVisitToSettingsRemembersItsOwnPreviousPage() {
        var returnPage = SettingsReturnPage()
        returnPage.pageChanged(from: .history, to: .general)
        returnPage.pageChanged(from: .general, to: .history)
        returnPage.pageChanged(from: .history, to: .style)
        returnPage.pageChanged(from: .style, to: .speech)
        XCTAssertEqual(returnPage.page, .style)
    }
}
