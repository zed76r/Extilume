import AppKit
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

@MainActor
final class MenuBarApplicationTests: XCTestCase {
    func testMenuShowsFixedModeAndUpdatesObservedStatus() async throws {
        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()

        XCTAssertEqual(delegate.menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
            "模式：外屏主屏", "等待外屏连接", "重试", "重试恢复", "保留当前配置", "打开显示设置", "退出并恢复"
        ])
        XCTAssertFalse(delegate.menu.autoenablesItems)
        XCTAssertFalse(try item("模式：外屏主屏", in: delegate).isEnabled)
        XCTAssertTrue(try item("重试", in: delegate).isHidden)
        XCTAssertTrue(try item("重试恢复", in: delegate).isHidden)
        XCTAssertTrue(try item("退出并恢复", in: delegate).isEnabled)
        XCTAssertEqual(try item("退出并恢复", in: delegate).keyEquivalent, "q")
        XCTAssertEqual(try item("退出并恢复", in: delegate).keyEquivalentModifierMask, .command)
        XCTAssertEqual(fixture.session.starts.count, 1)
        XCTAssertTrue(fixture.session.starts[0].registerEvents)
        XCTAssertFalse(fixture.session.starts[0].recoveryOnly)

        fixture.session.emit(.unsupported("镜像显示"))
        await drainMainQueue()
        XCTAssertFalse(try item("暂不支持：镜像显示", in: delegate).isEnabled)
        XCTAssertTrue(try item("打开显示设置", in: delegate).isEnabled)
    }

    func testEveryStatusRendersMenuItemsWithExplicitActionPermissions() async throws {
        typealias ActionExpectation = (hidden: Bool, enabled: Bool)
        let cases: [(status: PrimarySessionStatus, text: String, actions: [String: ActionExpectation])] = [
            (.waiting, "等待外屏连接", [
                "重试": (true, false), "重试恢复": (true, false), "保留当前配置": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.unsupported("镜像显示"), "暂不支持：镜像显示", [
                "重试": (true, false), "重试恢复": (true, false), "保留当前配置": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.applying, "正在应用外屏主屏…", [
                "重试": (true, false), "重试恢复": (true, false), "保留当前配置": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.applied, "外屏主屏已生效", [
                "重试": (true, false), "重试恢复": (true, false), "保留当前配置": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.manualConfiguration, "当前使用手动配置", [
                "重试": (true, false), "重试恢复": (true, false), "保留当前配置": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.applicationFailedRestored, "应用失败，已恢复", [
                "重试": (false, true), "重试恢复": (true, false), "保留当前配置": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.recoveryIncomplete, "恢复未完成", [
                "重试": (true, false), "重试恢复": (false, true), "保留当前配置": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, false)
            ]),
            (.unconfirmed, "无法确认显示状态", [
                "重试": (true, false), "重试恢复": (false, true), "保留当前配置": (false, true),
                "打开显示设置": (false, true), "退出并恢复": (false, false)
            ]),
            (.confirmationFailed, "未能保留当前配置", [
                "重试": (true, false), "重试恢复": (false, true), "保留当前配置": (false, true),
                "打开显示设置": (false, true), "退出并恢复": (false, false)
            ]),
            (.restoringAndQuitting, "正在恢复并退出…", [
                "重试": (true, false), "重试恢复": (true, false), "保留当前配置": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, false)
            ]),
            (.quitFailed, "恢复失败，尚未退出", [
                "重试": (true, false), "重试恢复": (false, true), "保留当前配置": (false, true),
                "打开显示设置": (false, true), "退出并恢复": (false, false)
            ]),
            (.quitWaitingForDisplays, "显示器未齐，等待恢复退出", [
                "重试": (true, false), "重试恢复": (false, true), "保留当前配置": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, false)
            ])
        ]

        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()
        let mode = try item("模式：外屏主屏", in: delegate)
        let statusItem = try item("等待外屏连接", in: delegate)

        for expected in cases {
            fixture.session.emit(expected.status)
            await drainMainQueue()

            XCTAssertEqual(statusItem.title, expected.text)
            XCTAssertFalse(mode.isEnabled, expected.text)
            XCTAssertFalse(statusItem.isEnabled, expected.text)
            for (title, actionExpectation) in expected.actions {
                let menuItem = try item(title, in: delegate)
                XCTAssertEqual(menuItem.isHidden, actionExpectation.hidden, "\(expected.text): \(title) hidden")
                XCTAssertEqual(menuItem.isEnabled, actionExpectation.enabled, "\(expected.text): \(title) enabled")
            }
        }
    }

    func testRetryDispatchImmediatelyDisablesFurtherRetry() async throws {
        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()
        fixture.session.emit(.applicationFailedRestored)
        await drainMainQueue()
        let retry = try item("重试", in: delegate)
        XCTAssertFalse(retry.isHidden)
        XCTAssertTrue(retry.isEnabled)

        try dispatch(retry)
        try dispatch(retry)

        XCTAssertEqual(fixture.session.retries, 1)
        XCTAssertFalse(retry.isEnabled)
        XCTAssertTrue(retry.isHidden)
        XCTAssertNotNil(delegate.menu.item(withTitle: "正在应用外屏主屏…"))
        XCTAssertTrue(try item("退出并恢复", in: delegate).isEnabled)
    }

    func testUnconfirmedStatusRejectsTakeoverAndRepeatedRecovery() async throws {
        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()
        fixture.session.emit(.unconfirmed)
        await drainMainQueue()
        let recover = try item("重试恢复", in: delegate)
        XCTAssertFalse(recover.isHidden)
        XCTAssertTrue(recover.isEnabled)
        XCTAssertTrue(try item("重试", in: delegate).isHidden)
        XCTAssertFalse(try item("退出并恢复", in: delegate).isEnabled)
        try dispatch(try item("重试", in: delegate))
        try dispatch(try item("退出并恢复", in: delegate))
        XCTAssertEqual(fixture.session.retries, 0)
        XCTAssertEqual(fixture.terminationRequests, 0)

        try dispatch(recover)
        try dispatch(recover)
        XCTAssertEqual(fixture.session.recoveries, 1)
        XCTAssertFalse(recover.isEnabled)
        XCTAssertNotNil(delegate.menu.item(withTitle: "正在恢复…"))

        fixture.session.emit(.applicationFailedRestored)
        await drainMainQueue()
        XCTAssertTrue(recover.isHidden)
        XCTAssertTrue(try item("重试", in: delegate).isEnabled)
    }

    func testSettingsAndQuitMenuActionsUseInjectedSystemBoundaries() throws {
        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()

        try dispatch(try item("打开显示设置", in: delegate))
        try dispatch(try item("退出并恢复", in: delegate))

        XCTAssertEqual(fixture.openedURLs.map(\.absoluteString), ["x-apple.systempreferences:com.apple.Displays-Settings.extension"])
        XCTAssertEqual(fixture.terminationRequests, 1)
        XCTAssertEqual(fixture.session.quitCompletions.count, 0)
    }

    func testFailedTerminationCancelsAndLateStatusCannotReplacePendingExit() async throws {
        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertEqual(fixture.session.quitCompletions.count, 1)
        XCTAssertTrue(fixture.terminationReplies.isEmpty)
        XCTAssertFalse(try item("退出并恢复", in: delegate).isEnabled)

        fixture.session.emit(.applied)
        await drainMainQueue()
        XCTAssertNotNil(delegate.menu.item(withTitle: "正在恢复并退出…"))
        fixture.session.quitCompletions[0](false)
        await drainMainQueue()

        XCTAssertEqual(fixture.terminationReplies, [false])
        XCTAssertNotNil(delegate.menu.item(withTitle: "恢复失败，尚未退出"))
        let recover = try item("重试恢复", in: delegate)
        XCTAssertFalse(recover.isHidden)
        XCTAssertTrue(recover.isEnabled)
        try dispatch(recover)
        XCTAssertEqual(fixture.terminationRequests, 1)
        XCTAssertEqual(fixture.session.recoveries, 0)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertEqual(fixture.session.quitCompletions.count, 2)
    }

    func testWaitingForDisplaysSurvivesEitherTerminationCallbackOrderAndRetriesExit() async throws {
        for statusFirst in [true, false] {
            let fixture = Fixture()
            let delegate = fixture.delegate
            delegate.startSession()
            XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
            if statusFirst {
                fixture.session.emit(.quitWaitingForDisplays)
                await drainMainQueue()
                XCTAssertNotNil(delegate.menu.item(withTitle: "显示器未齐，等待恢复退出"))
                let recover = try item("重试恢复", in: delegate)
                XCTAssertFalse(recover.isEnabled)
                try dispatch(recover)
                XCTAssertEqual(fixture.terminationRequests, 0)
            }
            fixture.session.quitCompletions[0](false)
            await drainMainQueue()
            XCTAssertEqual(fixture.terminationReplies, [false])
            if !statusFirst {
                XCTAssertNotNil(delegate.menu.item(withTitle: "恢复失败，尚未退出"))
                fixture.session.emit(.quitWaitingForDisplays)
                await drainMainQueue()
            }

            let state = try item("显示器未齐，等待恢复退出", in: delegate)
            let recover = try item("重试恢复", in: delegate)
            let hint = "请打开笔记本上盖或接回原外接显示器，再点“重试恢复”以恢复并退出。"
            XCTAssertEqual(state.toolTip, hint)
            XCTAssertEqual(recover.toolTip, hint)
            XCTAssertFalse(recover.isHidden)
            XCTAssertTrue(recover.isEnabled)
            for title in ["重试", "保留当前配置", "退出并恢复"] {
                let action = try item(title, in: delegate)
                XCTAssertFalse(action.isEnabled)
                try dispatch(action)
            }
            XCTAssertEqual(fixture.session.retries, 0)
            XCTAssertEqual(fixture.session.confirmations, 0)
            XCTAssertEqual(fixture.terminationRequests, 0)

            try dispatch(recover)
            XCTAssertEqual(fixture.terminationRequests, 1)
            XCTAssertEqual(fixture.session.recoveries, 0)
            XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
            XCTAssertEqual(fixture.session.quitCompletions.count, 2)
            XCTAssertNil(recover.toolTip)
            XCTAssertNil(try item("正在恢复并退出…", in: delegate).toolTip)
            // A later ordinary failure must not inherit the previous missing-display state.
            fixture.session.quitCompletions[1](false)
            await drainMainQueue()
            XCTAssertEqual(fixture.terminationReplies, [false, false])
            XCTAssertNotNil(delegate.menu.item(withTitle: "恢复失败，尚未退出"))
            XCTAssertTrue(try item("保留当前配置", in: delegate).isEnabled)
        }
    }

    func testSuccessfulTerminationRepliesOnlyAfterRecoveryCompletion() async {
        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertTrue(fixture.terminationReplies.isEmpty)

        fixture.session.quitCompletions[0](true)
        await drainMainQueue()

        XCTAssertEqual(fixture.terminationReplies, [true])
        XCTAssertEqual(fixture.session.quitCompletions.count, 1)
    }

    func testInitializationFailureRebuildsOnlyForRecovery() async throws {
        let fixture = Fixture()
        fixture.failNextCreation = true
        let delegate = fixture.delegate
        delegate.startSession()
        XCTAssertNotNil(delegate.menu.item(withTitle: "恢复未完成"))
        XCTAssertTrue(fixture.session.starts.isEmpty)
        let recover = try item("重试恢复", in: delegate)
        XCTAssertFalse(recover.isHidden)
        XCTAssertTrue(recover.isEnabled)

        try dispatch(recover)
        try dispatch(recover)
        XCTAssertEqual(fixture.creations, 2)
        XCTAssertEqual(fixture.session.starts.count, 1)
        XCTAssertTrue(fixture.session.starts[0].recoveryOnly)
        XCTAssertEqual(fixture.session.retries, 0)
        fixture.session.emit(.applicationFailedRestored)
        await drainMainQueue()
        XCTAssertEqual(fixture.terminationRequests, 0)
        XCTAssertTrue(try item("重试", in: delegate).isEnabled)
    }

    func testMissingControllerCancelsQuitAndRebuildsBeforeRetryingExit() async throws {
        let fixture = Fixture()
        fixture.failNextCreation = true
        let delegate = fixture.delegate
        delegate.startSession()
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateCancel)
        XCTAssertNotNil(delegate.menu.item(withTitle: "恢复失败，尚未退出"))

        try dispatch(try item("重试恢复", in: delegate))
        XCTAssertTrue(fixture.session.starts[0].recoveryOnly)
        XCTAssertEqual(fixture.terminationRequests, 0)
        fixture.session.emit(.applicationFailedRestored)
        await drainMainQueue()
        XCTAssertEqual(fixture.terminationRequests, 1)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertEqual(fixture.session.quitCompletions.count, 1)
    }

    func testConfirmDispatchBlocksCompetingActionsUntilSaved() async throws {
        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()
        let confirm = try item("保留当前配置", in: delegate)
        XCTAssertTrue(confirm.isHidden)
        try dispatch(confirm)
        XCTAssertEqual(fixture.session.confirmations, 0)
        fixture.session.emit(.unconfirmed)
        await drainMainQueue()
        XCTAssertFalse(confirm.isHidden)
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertEqual(confirm.toolTip, "仅保存当前配置作为恢复目标；下一次连接或唤醒时才重新应用外屏主屏。若已请求退出，则不再自动接管。")

        try dispatch(confirm)
        try dispatch(confirm)
        for title in ["重试", "重试恢复", "打开显示设置", "退出并恢复"] {
            let action = try item(title, in: delegate)
            XCTAssertFalse(action.isEnabled, title)
            try dispatch(action)
        }
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertNotNil(delegate.menu.item(withTitle: "正在保留当前配置…"))
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateCancel)
        XCTAssertEqual(fixture.session.confirmations, 1)
        XCTAssertEqual(fixture.session.retries, 0)
        XCTAssertEqual(fixture.session.recoveries, 0)
        XCTAssertTrue(fixture.session.quitCompletions.isEmpty)
        XCTAssertTrue(fixture.openedURLs.isEmpty)
        XCTAssertEqual(fixture.terminationRequests, 0)

        fixture.session.emit(.manualConfiguration)
        await drainMainQueue()
        XCTAssertNotNil(delegate.menu.item(withTitle: "当前使用手动配置"))
        XCTAssertTrue(confirm.isHidden)
        XCTAssertTrue(try item("退出并恢复", in: delegate).isEnabled)
        XCTAssertTrue(try item("打开显示设置", in: delegate).isEnabled)
        XCTAssertEqual(fixture.session.retries, 0)
    }

    func testConfirmationFailureAllowsRetryWithoutNewTakeover() async throws {
        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()
        fixture.session.emit(.unconfirmed)
        await drainMainQueue()
        let confirm = try item("保留当前配置", in: delegate)
        try dispatch(confirm)
        fixture.session.emit(.confirmationFailed)
        await drainMainQueue()

        XCTAssertNotNil(delegate.menu.item(withTitle: "未能保留当前配置"))
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertTrue(try item("重试恢复", in: delegate).isEnabled)
        XCTAssertFalse(try item("重试", in: delegate).isEnabled)
        XCTAssertFalse(try item("退出并恢复", in: delegate).isEnabled)
        try dispatch(confirm)
        XCTAssertEqual(fixture.session.confirmations, 2)
        fixture.session.emit(.recoveryIncomplete)
        await drainMainQueue()
        XCTAssertTrue(confirm.isHidden)
        XCTAssertTrue(try item("重试恢复", in: delegate).isEnabled)
        XCTAssertEqual(fixture.session.retries, 0)
    }

    func testFailedQuitAllowsExplicitConfirmationButRecoveryBlocksIt() async throws {
        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()
        fixture.session.emit(.quitFailed)
        await drainMainQueue()
        let confirm = try item("保留当前配置", in: delegate)
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertEqual(confirm.toolTip, "仅保存当前配置作为恢复目标；不会恢复自动接管，请再次退出并恢复。")
        try dispatch(confirm)
        XCTAssertEqual(fixture.session.confirmations, 1)
        fixture.session.emit(.unconfirmed)
        await drainMainQueue()
        try dispatch(try item("重试恢复", in: delegate))
        XCTAssertFalse(confirm.isEnabled)
        try dispatch(confirm)
        XCTAssertEqual(fixture.session.confirmations, 1)
        XCTAssertEqual(fixture.session.recoveries, 1)
    }

    private func item(_ title: String, in delegate: MenuBarApplicationDelegate) throws -> NSMenuItem {
        try XCTUnwrap(delegate.menu.item(withTitle: title))
    }

    private func dispatch(_ item: NSMenuItem) throws {
        // Dispatch even a disabled item's selector to exercise the handler's duplicate guard.
        let action = try XCTUnwrap(item.action)
        let target = try XCTUnwrap(item.target)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: target, from: item))
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    private final class FakeSession: PrimaryApplicationControlling {
        var starts: [(registerEvents: Bool, recoveryOnly: Bool)] = []
        var retries = 0
        var recoveries = 0
        var confirmations = 0
        var quitCompletions: [@Sendable (Bool) -> Void] = []
        private var onStatus: (@Sendable (PrimarySessionStatus) -> Void)?

        func startApplication(registerEvents: Bool, recoveryOnly: Bool, onStatus: @escaping @Sendable (PrimarySessionStatus) -> Void) {
            starts.append((registerEvents, recoveryOnly))
            self.onStatus = onStatus
        }

        func retryApplication() { retries += 1 }
        func recoverApplication() { recoveries += 1 }
        func confirmCurrentConfiguration() { confirmations += 1 }
        func quitApplication(completion: @escaping @Sendable (Bool) -> Void) { quitCompletions.append(completion) }
        func emit(_ status: PrimarySessionStatus) { onStatus?(status) }
    }

    @MainActor
    private final class Fixture {
        enum Failure: Error { case injected }
        let session = FakeSession()
        var failNextCreation = false
        var creations = 0
        var terminationRequests = 0
        var terminationReplies: [Bool] = []
        var openedURLs: [URL] = []
        lazy var delegate = MenuBarApplicationDelegate(
            controllerFactory: { [unowned self] in
                creations += 1
                if failNextCreation {
                    failNextCreation = false
                    throw Failure.injected
                }
                return session
            },
            requestTermination: { [unowned self] in terminationRequests += 1 },
            replyTermination: { [unowned self] in terminationReplies.append($0) },
            openSettings: { [unowned self] in openedURLs.append($0) }
        )
    }
}
