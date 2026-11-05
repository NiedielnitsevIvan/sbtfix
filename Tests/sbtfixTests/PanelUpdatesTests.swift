import XCTest
@testable import sbtfix

final class PanelUpdatesTests: XCTestCase {
    func testRedrawsOnlyWhileTheMenuIsOpen() {
        let controller = HeadphoneController.preview(status: .connected)
        let updates = PanelUpdates(controller)
        var redraws = 0
        let subscription = updates.objectWillChange.sink { redraws += 1 }

        controller.setEqualizer(.bright)
        XCTAssertEqual(redraws, 0)
        updates.isVisible = true
        XCTAssertEqual(redraws, 1, "opening the menu catches the panel up")
        controller.setEqualizer(.vocal)
        XCTAssertEqual(redraws, 2)
        updates.isVisible = false
        controller.setEqualizer(.off)
        XCTAssertEqual(redraws, 2)
        withExtendedLifetime(subscription) {}
    }
}
