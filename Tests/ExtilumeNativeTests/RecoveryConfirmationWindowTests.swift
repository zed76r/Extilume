import AppKit
import XCTest
@testable import ExtilumeNative

@MainActor
final class RecoveryConfirmationWindowTests: XCTestCase {
    func testLoadingDoesNotRecordOrProvideDefaultConfirmation() async throws {
        var calls = 0
        var finishes = 0
        let controller = RecoveryConfirmationWindowController(record: { calls += 1 }, finish: { finishes += 1 })
        XCTAssertNil(controller.window)
        controller.loadWindow()
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertTrue(window.contentView === controller.verificationView)
        XCTAssertTrue(window.delegate === controller)
        XCTAssertNil(window.defaultButtonCell)
        XCTAssertTrue(controller.confirmButton.keyEquivalent.isEmpty)
        XCTAssertFalse(controller.recorded)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(finishes, 0)
    }

    func testConfirmationRecordsSynchronouslyOnceAndFinishesAutomatically() async {
        var calls = 0
        var finishes = 0
        let controller = RecoveryConfirmationWindowController(record: { calls += 1 }, finish: { finishes += 1 })
        controller.confirmButton.performClick(nil)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(controller.recorded)
        XCTAssertEqual(finishes, 1)
        XCTAssertFalse(controller.confirmButton.isEnabled)
        controller.confirmButton.performClick(nil)
        controller.endButton.performClick(nil)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(finishes, 1)
    }

    func testCancelAndWindowCloseNeverRecordAndFinishOnce() async {
        for cancelWithButton in [true, false] {
            var calls = 0
            var finishes = 0
            let controller = RecoveryConfirmationWindowController(record: { calls += 1 }, finish: { finishes += 1 })
            if cancelWithButton {
                controller.endButton.performClick(nil)
            } else {
                controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            }
            controller.confirmButton.performClick(nil)
            controller.endButton.performClick(nil)
            controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(finishes, 1)
            XCTAssertFalse(controller.recorded)
            XCTAssertFalse(controller.confirmButton.isEnabled)
        }
    }

    func testFailureCannotRetryAndDoesNotExposeOriginalError() async {
        var calls = 0
        var finishes = 0
        let controller = RecoveryConfirmationWindowController(record: {
            calls += 1
            throw NSError(domain: "private-detail", code: 1, userInfo: [NSLocalizedDescriptionKey: "private-detail"])
        }, finish: { finishes += 1 })
        controller.confirmButton.performClick(nil)
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(controller.recorded)
        XCTAssertFalse(controller.confirmButton.isEnabled)
        XCTAssertEqual(finishes, 0)
        XCTAssertEqual(controller.statusLabel.stringValue, "记录失败，无法再次确认。请关闭窗口并检查本次结果。")
        controller.confirmButton.performClick(nil)
        XCTAssertEqual(calls, 1)
        controller.endButton.performClick(nil)
        controller.endButton.performClick(nil)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(finishes, 1)
    }
}
