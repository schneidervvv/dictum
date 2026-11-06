import AppKit
import SwiftUI
import XCTest
@testable import TypeWhisper

@MainActor
final class GroupedFormRowTests: XCTestCase {
    private func width(of row: some View) -> CGFloat {
        NSHostingView(rootView: row.fixedSize()).fittingSize.width
    }

    func testRowInsetsContentByFourteenPointsOnEachSideByDefault() {
        let bare = width(of: Color.clear.frame(width: 100, height: 20))
        let row = width(of: GroupedFormRow { Color.clear.frame(width: 100, height: 20) })
        XCTAssertEqual(row - bare, 28, accuracy: 0.5)
    }

    func testRowInsideAPaddedContainerCanDropItsOwnInset() {
        let bare = width(of: Color.clear.frame(width: 100, height: 20))
        let row = width(of: GroupedFormRow(horizontalInset: 0) { Color.clear.frame(width: 100, height: 20) })
        XCTAssertEqual(row - bare, 0, accuracy: 0.5)
    }
}
