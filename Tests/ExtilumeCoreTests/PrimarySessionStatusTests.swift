import XCTest
@testable import ExtilumeCore

final class PrimarySessionStatusTests: XCTestCase {
    func testEveryStatusHasDistinctTextAndPermittedActions() {
        let cases: [(PrimarySessionStatus, String, Bool, Bool, Bool)] = [
            (.waiting, "等待外屏连接", false, false, true),
            (.unsupported("镜像显示"), "暂不支持：镜像显示", false, false, true),
            (.applying, "正在应用外屏主屏…", false, false, true),
            (.applied, "外屏主屏已生效", false, false, true),
            (.manualConfiguration, "排列已确认，可切换主屏", true, false, true),
            (.manualConfigurationForQuit, "排列已确认，可以退出", false, false, true),
            (.applicationFailedRestored, "应用失败，已恢复", true, false, true),
            (.recoveryIncomplete, "恢复未完成", false, true, false),
            (.unconfirmed, "请确认退出时恢复的排列", false, true, false),
            (.confirmationFailed, "排列确认失败", false, true, false),
            (.restoringAndQuitting, "正在恢复并退出…", false, false, false),
            (.quitFailed, "恢复失败，尚未退出", false, true, false),
            (.quitWaitingForDisplays, "显示器未齐，等待恢复退出", false, true, false)
        ]
        for (status, text, retry, recover, quit) in cases {
            XCTAssertEqual(status.text, text)
            XCTAssertEqual(status.canRetryApplication, retry, text)
            XCTAssertEqual(status.canRetryRecovery, recover, text)
            XCTAssertEqual(status.needsRecovery, recover, text)
            XCTAssertEqual(status.canQuit, quit, text)
            XCTAssertFalse(status.canRetryApplication && status.canRetryRecovery, text)
            XCTAssertEqual(status.canConfirmConfiguration,
                           [.unconfirmed, .confirmationFailed, .quitFailed].contains(status), text)
        }
        XCTAssertEqual(Set(cases.map { $0.0.text }).count, cases.count)
    }
}
