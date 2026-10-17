import AppKit
import XCTest
@testable import ExtilumeNative

@MainActor
final class ConnectionTimingWindowTests: XCTestCase {
    func testExplicitWindowLoadingBuildsHiddenWindowWithoutStartingFlow() async throws {
        var calls = 0
        let controller = ConnectionTimingWindowController(record: { _ in calls += 1 }, finish: {})
        XCTAssertNil(controller.window)
        controller.loadWindow()
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertTrue(window.contentView === controller.verificationView)
        XCTAssertTrue(window.delegate === controller)
        XCTAssertNil(window.defaultButtonCell)
        XCTAssertEqual(calls, 0)
    }

    func testOnlyCurrentStepDispatchesAndDoesNotAutomaticallyFinish() async {
        var actions: [ConnectionTimingAction] = []
        var finishes = 0
        let controller = ConnectionTimingWindowController(record: { actions.append($0) }, finish: { finishes += 1 })
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNil(controller.verificationView.window)
        XCTAssertEqual(controller.actionButtons.map(\.isEnabled), [true, false, false, false])
        controller.actionButtons[3].performClick(nil)
        XCTAssertTrue(actions.isEmpty)
        for index in 0..<4 {
            XCTAssertEqual(controller.actionButtons.map(\.isEnabled), (0..<4).map { $0 == index })
            controller.actionButtons[index].performClick(nil)
            controller.actionButtons[index].performClick(nil)
            XCTAssertEqual(actions.count, index + 1)
        }
        XCTAssertEqual(actions, [.armUnplug, .confirmUnplug, .armReconnect, .confirmReconnect])
        XCTAssertTrue(controller.actionButtons.allSatisfy { !$0.isEnabled && $0.keyEquivalent.isEmpty })
        XCTAssertEqual(finishes, 0)
        controller.endButton.performClick(nil)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        XCTAssertEqual(finishes, 1)
        XCTAssertNil(controller.verificationView.window)
    }

    func testRecordErrorStopsAllStepsWithoutExposingError() async {
        struct PrivateError: Error {}
        for failureStep in 0..<4 {
            var calls = 0
            var finishes = 0
            let controller = ConnectionTimingWindowController(record: { _ in
                calls += 1
                if calls == failureStep + 1 { throw PrivateError() }
            }, finish: { finishes += 1 })
            for button in controller.actionButtons { button.performClick(nil) }
            XCTAssertEqual(calls, failureStep + 1)
            XCTAssertTrue(controller.actionButtons.allSatisfy { !$0.isEnabled })
            XCTAssertEqual(controller.statusLabel.stringValue, "记录失败，已停止后续标记。请结束记录并检查本次结果。")
            controller.endButton.performClick(nil)
            controller.endButton.performClick(nil)
            XCTAssertEqual(finishes, 1)
        }
    }

    func testCloseBeforeFirstActionFinishesOnceAndDisablesMarking() async {
        var calls = 0
        var finishes = 0
        let controller = ConnectionTimingWindowController(record: { _ in calls += 1 }, finish: { finishes += 1 })
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        controller.actionButtons[0].performClick(nil)
        controller.endButton.performClick(nil)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(finishes, 1)
    }
}
