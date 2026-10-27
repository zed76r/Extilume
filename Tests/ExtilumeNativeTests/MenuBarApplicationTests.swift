import AppKit
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

@MainActor
final class MenuBarApplicationTests: XCTestCase {
    func testOnlyExternalStatePermissionsAndDevelopmentMarker() async throws {
        let states: [PrimarySessionStatus] = [.waiting, .unsupported("条件不符"), .applying, .applied,
            .manualConfiguration, .manualConfigurationForQuit, .applicationFailedRestored, .recoveryIncomplete,
            .unconfirmed, .confirmationFailed, .restoringAndQuitting, .quitFailed, .quitWaitingForDisplays]
        for state in states {
            let session = ModeSession()
            session.selectedMode = .externalOnly
            let delegate = MenuBarApplicationDelegate(controllerFactory: { session }, developmentBuild: true)
            delegate.startSession()
            session.emit(state)
            await drainMainQueue()
            let marker = try item("开发版 · 仅外屏尚未准入日用", in: delegate)
            XCTAssertFalse(marker.isEnabled)
            let modesEnabled = !state.needsRecovery && state != .applying
                && state != .restoringAndQuitting && state != .manualConfigurationForQuit
            XCTAssertEqual(try item(DisplayApplicationMode.externalOnly.title, in: delegate).isEnabled, modesEnabled)
            XCTAssertEqual(try item("恢复双屏以调整排列", in: delegate).isHidden, state != .applied)
            XCTAssertEqual(try item("设为恢复布局", in: delegate).isHidden,
                           !((state.canConfirmConfiguration && state != .quitFailed) || state == .manualConfiguration))
            XCTAssertEqual(try item("退出并恢复", in: delegate).isEnabled, state.canQuit)
            if state == .applied { XCTAssertNotNil(delegate.menu.item(withTitle: "仅外屏已生效")) }
            XCTAssertTrue(delegate.accessibilityStatusLabel.contains(DisplayApplicationMode.externalOnly.title))
        }
    }

    func testMenuShowsFixedModeAndUpdatesObservedStatus() async throws {
        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()

        XCTAssertEqual(delegate.menu.items.filter { !$0.isSeparatorItem }.map(\.title), [
            "模式：外屏主屏", "等待外屏连接", "重试", "重试恢复", "设为恢复布局", "自动切到 PC", "", "打开显示设置", "退出并恢复"
        ])
        XCTAssertTrue(try item("自动切到 PC", in: delegate).isHidden)
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
                "重试": (true, false), "重试恢复": (true, false), "设为恢复布局": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.unsupported("镜像显示"), "暂不支持：镜像显示", [
                "重试": (true, false), "重试恢复": (true, false), "设为恢复布局": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.applying, "正在应用外屏主屏…", [
                "重试": (true, false), "重试恢复": (true, false), "设为恢复布局": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.applied, "外屏主屏已生效", [
                "重试": (true, false), "重试恢复": (true, false), "设为恢复布局": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.manualConfiguration, "排列已确认，可切换主屏", [
                "设为外屏主屏": (false, true), "重试恢复": (true, false), "设为恢复布局": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.manualConfigurationForQuit, "排列已确认，可以退出", [
                "重试": (true, false), "重试恢复": (true, false), "设为恢复布局": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.applicationFailedRestored, "应用失败，已恢复", [
                "重试": (false, true), "重试恢复": (true, false), "设为恢复布局": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, true)
            ]),
            (.recoveryIncomplete, "恢复未完成", [
                "重试": (true, false), "重试恢复": (false, true), "设为恢复布局": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, false)
            ]),
            (.unconfirmed, "请确认退出时恢复的排列", [
                "重试": (true, false), "重试恢复": (false, true), "设为恢复布局": (false, true),
                "打开显示设置": (false, true), "退出并恢复": (false, false)
            ]),
            (.confirmationFailed, "排列确认失败", [
                "重试": (true, false), "重试恢复": (false, true), "设为恢复布局": (false, true),
                "打开显示设置": (false, true), "退出并恢复": (false, false)
            ]),
            (.restoringAndQuitting, "正在恢复并退出…", [
                "重试": (true, false), "重试恢复": (true, false), "设为恢复布局": (true, false),
                "打开显示设置": (false, true), "退出并恢复": (false, false)
            ]),
            (.quitFailed, "恢复失败，尚未退出", [
                "重试": (true, false), "重试恢复": (false, true), "设为恢复布局": (false, true),
                "打开显示设置": (false, true), "退出并恢复": (false, false)
            ]),
            (.quitWaitingForDisplays, "显示器未齐，等待恢复退出", [
                "重试": (true, false), "重试恢复": (false, true), "设为恢复布局": (true, false),
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
        for (status, title) in [
            (PrimarySessionStatus.applicationFailedRestored, "重试"),
            (.manualConfiguration, "设为外屏主屏")
        ] {
            let fixture = Fixture()
            let delegate = fixture.delegate
            delegate.startSession()
            fixture.session.emit(status)
            await drainMainQueue()
            let retry = try item(title, in: delegate)
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
            for title in ["重试", "设为恢复布局", "退出并恢复"] {
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
            XCTAssertTrue(try item("设为恢复布局", in: delegate).isEnabled)
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
        fixture.session.emit(.applying)
        await drainMainQueue()
        XCTAssertTrue(delegate.accessibilityStatusLabel.contains("正在恢复…"))
        XCTAssertFalse(try item("退出并恢复", in: delegate).isEnabled)
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
        let confirm = try item("设为恢复布局", in: delegate)
        XCTAssertTrue(confirm.isHidden)
        try dispatch(confirm)
        XCTAssertEqual(fixture.session.confirmations, 0)
        fixture.session.emit(.unconfirmed)
        await drainMainQueue()
        XCTAssertFalse(confirm.isHidden)
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertEqual(confirm.toolTip, "将当前排列设为退出时的恢复目标，不会立即切换主屏。保存后可点“设为外屏主屏”，也可等待下一次连接或唤醒。若已请求退出，则不再自动接管。")

        try dispatch(confirm)
        try dispatch(confirm)
        fixture.session.emit(.applying)
        await drainMainQueue()
        for title in ["重试", "重试恢复", "打开显示设置", "退出并恢复"] {
            let action = try item(title, in: delegate)
            XCTAssertFalse(action.isEnabled, title)
            try dispatch(action)
        }
        XCTAssertFalse(confirm.isEnabled)
        XCTAssertNotNil(delegate.menu.item(withTitle: "正在确认排列…"))
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateCancel)
        XCTAssertEqual(fixture.session.confirmations, 1)
        XCTAssertEqual(fixture.session.retries, 0)
        XCTAssertEqual(fixture.session.recoveries, 0)
        XCTAssertTrue(fixture.session.quitCompletions.isEmpty)
        XCTAssertTrue(fixture.openedURLs.isEmpty)
        XCTAssertEqual(fixture.terminationRequests, 0)

        fixture.session.emit(.manualConfiguration)
        await drainMainQueue()
        XCTAssertNotNil(delegate.menu.item(withTitle: "排列已确认，可切换主屏"))
        XCTAssertTrue(confirm.isHidden)
        XCTAssertTrue(try item("退出并恢复", in: delegate).isEnabled)
        XCTAssertTrue(try item("打开显示设置", in: delegate).isEnabled)
        XCTAssertEqual(fixture.session.retries, 0)
        let apply = try item("设为外屏主屏", in: delegate)
        XCTAssertFalse(apply.isHidden)
        XCTAssertTrue(apply.isEnabled)
        try dispatch(apply)
        try dispatch(apply)
        XCTAssertEqual(fixture.session.retries, 1)
        XCTAssertFalse(apply.isEnabled)
        XCTAssertTrue(apply.isHidden)
    }

    func testConfirmationFailureAllowsRetryWithoutNewTakeover() async throws {
        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()
        fixture.session.emit(.unconfirmed)
        await drainMainQueue()
        let confirm = try item("设为恢复布局", in: delegate)
        try dispatch(confirm)
        fixture.session.emit(.confirmationFailed)
        await drainMainQueue()

        XCTAssertNotNil(delegate.menu.item(withTitle: "排列确认失败"))
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
        let confirm = try item("设为恢复布局", in: delegate)
        XCTAssertTrue(confirm.isEnabled)
        XCTAssertEqual(confirm.toolTip, "将当前排列设为退出时的恢复目标，不切换主屏；保存后请再次点“退出并恢复”。")
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

    func testConfirmationAfterFailedQuitAllowsExitWithoutTakeover() async throws {
        let fixture = Fixture()
        let delegate = fixture.delegate
        delegate.startSession()
        fixture.session.emit(.quitFailed)
        await drainMainQueue()
        try dispatch(try item("设为恢复布局", in: delegate))
        fixture.session.emit(.manualConfigurationForQuit)
        await drainMainQueue()

        XCTAssertNotNil(delegate.menu.item(withTitle: "排列已确认，可以退出"))
        XCTAssertNil(delegate.menu.item(withTitle: "设为外屏主屏"))
        for title in ["重试", "重试恢复", "设为恢复布局"] {
            let action = try item(title, in: delegate)
            XCTAssertTrue(action.isHidden)
            XCTAssertFalse(action.isEnabled)
            try dispatch(action)
        }
        XCTAssertEqual(fixture.session.retries, 0)
        XCTAssertEqual(fixture.session.recoveries, 0)
        XCTAssertEqual(fixture.session.confirmations, 1)
        let quit = try item("退出并恢复", in: delegate)
        XCTAssertTrue(quit.isEnabled)
        try dispatch(quit)
        XCTAssertEqual(fixture.terminationRequests, 1)
    }

    func testDualModeSelectionDispatchesRealActionsAndSeparatesSelectionFromApplication() async throws {
        let session = ModeSession()
        let delegate = MenuBarApplicationDelegate(controllerFactory: { session })
        delegate.startSession()
        XCTAssertNotNil(delegate.menu.item(withTitle: "请选择显示模式"))
        XCTAssertEqual(delegate.accessibilityStatusLabel, "Extilume，模式：未选择，请选择显示模式")
        let primary = try item("外屏主屏", in: delegate)
        let only = try item("仅外屏（停用内屏）", in: delegate)
        XCTAssertEqual(primary.state, .off)
        XCTAssertEqual(only.state, .off)
        try dispatch(only)
        try dispatch(primary)
        XCTAssertEqual(session.selections, [.externalOnly])
        XCTAssertEqual(only.state, .off)
        XCTAssertEqual(primary.state, .off)
        XCTAssertNotNil(delegate.menu.item(withTitle: "正在停用内屏…"))
        XCTAssertEqual(delegate.accessibilityStatusLabel, "Extilume，模式：仅外屏（停用内屏），正在停用内屏…")
        session.emit(.applied)
        await drainMainQueue()
        XCTAssertNotNil(delegate.menu.item(withTitle: "仅外屏已生效"))
        XCTAssertEqual(only.state, .on)
        XCTAssertEqual(primary.state, .off)
        session.selectedMode = .externalPrimary
        session.modeDidChange?()
        XCTAssertNotNil(delegate.menu.item(withTitle: "已选择模式，尚未应用"))
        XCTAssertEqual(primary.state, .off)
        XCTAssertEqual(only.state, .off)
        XCTAssertEqual(session.selections.count, 1)
        try dispatch(primary)
        XCTAssertEqual(session.selections, [.externalOnly, .externalPrimary])
        XCTAssertNotNil(delegate.menu.item(withTitle: "正在应用外屏主屏…"))
        XCTAssertEqual(primary.state, .off)
        session.emit(.applied)
        await drainMainQueue()
        XCTAssertEqual(primary.state, .on)
        XCTAssertEqual(only.state, .off)
    }

    func testSavedOnlyExternalRequiresSameModeExplicitActivationAndUsesModeSpecificConfirmation() async throws {
        let session = ModeSession()
        session.selectedMode = .externalOnly
        session.requiresExplicitActivation = true
        let delegate = MenuBarApplicationDelegate(controllerFactory: { session })
        delegate.startSession()
        XCTAssertNotNil(delegate.menu.item(withTitle: "已选择仅外屏，等待点击模式应用"))
        let only = try item("仅外屏（停用内屏）", in: delegate)
        XCTAssertEqual(only.state, .off)
        XCTAssertTrue(only.isEnabled)
        XCTAssertTrue(session.selections.isEmpty)
        session.emit(.applied)
        await drainMainQueue()
        XCTAssertEqual(only.state, .off)
        XCTAssertTrue(delegate.accessibilityStatusLabel.contains("等待点击模式应用"))
        try dispatch(only)
        XCTAssertEqual(only.state, .off)
        XCTAssertEqual(session.selections, [.externalOnly])
        session.emit(.unconfirmed)
        await drainMainQueue()
        let confirm = try item("设为恢复布局", in: delegate)
        XCTAssertTrue(try XCTUnwrap(confirm.toolTip).contains("不会立即停用内屏"))
        try dispatch(confirm)
        session.emit(.applying)
        await drainMainQueue()
        XCTAssertTrue(delegate.accessibilityStatusLabel.contains("正在确认排列…"))
        XCTAssertFalse(try item("外屏主屏", in: delegate).isEnabled)
        XCTAssertFalse(try item("退出并恢复", in: delegate).isEnabled)
        XCTAssertFalse(only.isEnabled)
        try dispatch(only)
        XCTAssertEqual(session.selections.count, 1)
        session.emit(.manualConfiguration)
        await drainMainQueue()
        XCTAssertNotNil(delegate.menu.item(withTitle: "双屏已恢复，可调整或确认排列"))
        try dispatch(try item("应用仅外屏", in: delegate))
        XCTAssertEqual(session.retries, 1)
        XCTAssertNotNil(delegate.menu.item(withTitle: "正在停用内屏…"))
    }

    func testDualModesRejectSelectionThroughoutRecoveryAndExit() async throws {
        let session = ModeSession()
        session.selectedMode = .externalOnly
        let delegate = MenuBarApplicationDelegate(controllerFactory: { session }, replyTermination: { _ in })
        delegate.startSession()
        let modes = try [item("外屏主屏", in: delegate), item("仅外屏（停用内屏）", in: delegate)]
        for status in [PrimarySessionStatus.applying, .recoveryIncomplete, .unconfirmed, .confirmationFailed,
                                             .restoringAndQuitting, .quitFailed, .quitWaitingForDisplays,
                                             .manualConfigurationForQuit] {
            session.emit(status)
            await drainMainQueue()
            for mode in modes {
                XCTAssertFalse(mode.isEnabled, status.text)
                XCTAssertEqual(mode.state, .off, status.text)
                try dispatch(mode)
            }
        }
        session.emit(.recoveryIncomplete)
        await drainMainQueue()
        try dispatch(try item("重试恢复", in: delegate))
        for mode in modes { try dispatch(mode) }
        XCTAssertEqual(session.recoveries, 1)
        XCTAssertNotNil(delegate.menu.item(withTitle: "正在恢复…"))
        session.emit(.applicationFailedRestored)
        await drainMainQueue()
        XCTAssertTrue(modes.allSatisfy(\.isEnabled))
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        for mode in modes {
            XCTAssertFalse(mode.isEnabled)
            try dispatch(mode)
        }
        XCTAssertTrue(session.selections.isEmpty)
        XCTAssertEqual(session.quitCompletions.count, 1)
        session.quitCompletions[0](false)
        await drainMainQueue()
        XCTAssertTrue(delegate.accessibilityStatusLabel.contains("恢复失败，尚未退出"))
        XCTAssertTrue(modes.allSatisfy { !$0.isEnabled })
    }

    func testRestoreForConfigurationRoutesOnlyFromAppliedOnlyExternalAndBlocksRepeatedActions() async throws {
        let session = ModeSession()
        session.selectedMode = .externalOnly
        let delegate = MenuBarApplicationDelegate(controllerFactory: { session })
        delegate.startSession()
        let restore = try item("恢复双屏以调整排列", in: delegate)
        XCTAssertTrue(restore.isHidden)
        XCTAssertFalse(restore.isEnabled)
        try dispatch(restore)
        XCTAssertEqual(session.configurationRestores, 0)
        session.emit(.applied)
        await drainMainQueue()
        XCTAssertFalse(restore.isHidden)
        XCTAssertTrue(restore.isEnabled)
        let only = try item("仅外屏（停用内屏）", in: delegate)
        XCTAssertEqual(only.state, .on)
        XCTAssertNotNil(restore.toolTip)
        try dispatch(restore)
        try dispatch(restore)
        session.emit(.applying)
        await drainMainQueue()
        try dispatch(try item("外屏主屏", in: delegate))
        XCTAssertEqual(session.configurationRestores, 1)
        XCTAssertTrue(session.selections.isEmpty)
        XCTAssertFalse(restore.isEnabled)
        XCTAssertFalse(try item("外屏主屏", in: delegate).isEnabled)
        XCTAssertFalse(only.isEnabled)
        XCTAssertFalse(try item("退出并恢复", in: delegate).isEnabled)
        XCTAssertEqual(only.state, .off)
        XCTAssertTrue(delegate.accessibilityStatusLabel.contains("正在恢复…"))
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateCancel)
        session.emit(.manualConfiguration)
        await drainMainQueue()
        XCTAssertTrue(restore.isHidden)
        XCTAssertTrue(try item("应用仅外屏", in: delegate).isEnabled)
        XCTAssertTrue(try item("退出并恢复", in: delegate).isEnabled)
        session.selectedMode = .externalPrimary
        session.emit(.applied)
        await drainMainQueue()
        XCTAssertTrue(restore.isHidden)
        try dispatch(restore)
        XCTAssertEqual(session.configurationRestores, 1)
    }

    func testModeCheckmarksRequireAppliedStatusForBothModes() async throws {
        for selected in [DisplayApplicationMode.externalPrimary, .externalOnly] {
            let session = ModeSession()
            session.selectedMode = selected
            let delegate = MenuBarApplicationDelegate(controllerFactory: { session }, replyTermination: { _ in })
            delegate.startSession()
            let modes = try [item("外屏主屏", in: delegate), item("仅外屏（停用内屏）", in: delegate)]
            XCTAssertTrue(modes.allSatisfy { $0.state == .off })
            for status in [PrimarySessionStatus.waiting, .unsupported("测试"), .applying,
                           .manualConfiguration, .applicationFailedRestored, .recoveryIncomplete,
                           .unconfirmed, .confirmationFailed, .restoringAndQuitting, .quitFailed,
                           .quitWaitingForDisplays, .manualConfigurationForQuit] {
                session.emit(.applied)
                await drainMainQueue()
                XCTAssertEqual(try item(selected.title, in: delegate).state, .on)
                session.emit(status)
                await drainMainQueue()
                XCTAssertTrue(modes.allSatisfy { $0.state == .off }, status.text)
            }
            session.emit(.applied)
            await drainMainQueue()
            XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
            XCTAssertTrue(modes.allSatisfy { $0.state == .off })
        }
    }

    func testHandoffAvailabilityIsExplicitAndRejectsUnavailableAction() throws {
        let session = ModeSession()
        let delegate = MenuBarApplicationDelegate(controllerFactory: { session })
        delegate.startSession()
        XCTAssertNil(delegate.menu.item(withTitle: "仅内屏（外屏给 PC）"))
        let existing = try item("外屏主屏", in: delegate)
        let unavailable = NSMenuItem(title: "仅内屏（外屏给 PC）", action: existing.action, keyEquivalent: "")
        unavailable.target = existing.target
        unavailable.representedObject = DisplayApplicationMode.internalOnly.rawValue
        try dispatch(unavailable)
        XCTAssertTrue(session.selections.isEmpty)
    }

    func testHandoffStatusRestoreAndExplicitReactivation() async throws {
        let session = ModeSession()
        session.availableModes.append(.internalOnly)
        let delegate = MenuBarApplicationDelegate(controllerFactory: { session })
        delegate.startSession()
        let handoff = try item("仅内屏（外屏给 PC）", in: delegate)
        try dispatch(handoff)
        XCTAssertEqual(session.selections, [.internalOnly])
        XCTAssertEqual(handoff.state, .off)
        XCTAssertEqual(delegate.accessibilityStatusLabel, "Extilume，模式：仅内屏（外屏给 PC），正在停用外接屏…")
        XCTAssertFalse(handoff.isEnabled)
        session.emit(.applied)
        await drainMainQueue()
        XCTAssertEqual(handoff.state, .on)
        XCTAssertEqual(delegate.accessibilityStatusLabel, "Extilume，模式：仅内屏（外屏给 PC），外接屏已停用，请切换显示器到 PC")
        let restore = try item("恢复外接屏", in: delegate)
        XCTAssertFalse(restore.isHidden)
        XCTAssertTrue(restore.isEnabled)
        XCTAssertTrue(try XCTUnwrap(restore.toolTip).contains("不会自动重新停用外接屏"))
        try dispatch(restore)
        try dispatch(restore)
        try dispatch(handoff)
        XCTAssertEqual(session.configurationRestores, 1)
        XCTAssertEqual(session.selections, [.internalOnly])
        XCTAssertEqual(handoff.state, .off)
        XCTAssertFalse(restore.isEnabled)
        XCTAssertFalse(try item("退出并恢复", in: delegate).isEnabled)
        XCTAssertTrue(delegate.accessibilityStatusLabel.contains("正在恢复…"))
        session.emit(.manualConfiguration)
        await drainMainQueue()
        XCTAssertTrue(delegate.accessibilityStatusLabel.contains("外接屏已恢复，请切换显示器到 Mac"))
        XCTAssertTrue(restore.isHidden)
        XCTAssertEqual(handoff.state, .off)
        XCTAssertEqual(session.selections, [.internalOnly])
        XCTAssertEqual(session.retries, 0)
        XCTAssertTrue(try item("设为恢复布局", in: delegate).isHidden)
        try dispatch(try item("应用仅内屏", in: delegate))
        XCTAssertEqual(session.retries, 1)
        XCTAssertTrue(delegate.accessibilityStatusLabel.contains("正在停用外接屏…"))
    }

    func testHandoffErrorsAndBusyStatesKeepModesExclusive() async throws {
        let session = ModeSession()
        session.availableModes.append(.internalOnly)
        session.selectedMode = .internalOnly
        let delegate = MenuBarApplicationDelegate(controllerFactory: { session }, replyTermination: { _ in })
        delegate.startSession()
        let modes = try session.availableModes.map { try item($0.title, in: delegate) }
        for status in [PrimarySessionStatus.applying, .recoveryIncomplete, .quitFailed,
                       .unconfirmed, .restoringAndQuitting, .quitWaitingForDisplays] {
            session.emit(status)
            await drainMainQueue()
            XCTAssertTrue(modes.allSatisfy { !$0.isEnabled && $0.state == .off })
            for mode in modes { try dispatch(mode) }
            XCTAssertTrue(session.selections.isEmpty)
            let restore = try item("恢复外接屏", in: delegate)
            XCTAssertTrue(restore.isHidden)
            XCTAssertFalse(restore.isEnabled)
            if status != .applying {
                XCTAssertTrue(delegate.accessibilityStatusLabel.contains(status.text))
            }
        }
    }

    func testInputSettingsAreHiddenUntilCandidateOrRecoveryIsVisible() throws {
        let session = ModeSession()
        let delegate = MenuBarApplicationDelegate(controllerFactory: { session })
        delegate.startSession()
        let settings = try item("自动切到 PC", in: delegate)
        XCTAssertTrue(settings.isHidden)
        session.selectedMode = .internalOnly
        session.modeDidChange?()
        XCTAssertFalse(settings.isHidden)
        let submenu = try XCTUnwrap(settings.submenu)
        XCTAssertFalse(try XCTUnwrap(submenu.item(withTitle: "当前连接尚未验收自动输入源切换")).isEnabled)
        let toggle = try XCTUnwrap(submenu.item(withTitle: "启用自动切到 PC"))
        XCTAssertEqual(toggle.state, .off)
        XCTAssertFalse(toggle.isEnabled)
        try dispatch(toggle)
        XCTAssertTrue(session.inputSelections.isEmpty)
        XCTAssertTrue(session.automaticChanges.isEmpty)
    }

    func testVerifiedInputSettingsRequireExplicitPortAndToggleAndPreserveSeparateResult() async throws {
        let session = ModeSession()
        session.availableModes.append(.internalOnly)
        session.inputUnavailableReason = nil
        session.inputOptions = [0x11, 0x12]
        let delegate = MenuBarApplicationDelegate(controllerFactory: { session })
        delegate.startSession()
        let settings = try item("自动切到 PC", in: delegate)
        func option(_ title: String) throws -> NSMenuItem {
            try XCTUnwrap(settings.submenu?.item(withTitle: title))
        }
        XCTAssertFalse(try option("启用自动切到 PC").isEnabled)
        XCTAssertTrue(session.inputSelections.isEmpty)
        try dispatch(try option("PC 输入 0x12（请确认端口）"))
        XCTAssertEqual(session.inputSelections, [0x12])
        XCTAssertEqual(try option("PC 输入 0x12（请确认端口）").state, .on)
        XCTAssertEqual(try option("PC 输入 0x11（请确认端口）").state, .off)
        XCTAssertTrue(try option("启用自动切到 PC").isEnabled)
        XCTAssertTrue(session.automaticChanges.isEmpty)
        try dispatch(try option("启用自动切到 PC"))
        XCTAssertEqual(session.automaticChanges, [true])
        XCTAssertEqual(try option("启用自动切到 PC").state, .on)
        session.inputResultText = "输入源未确认，请手动检查显示器"
        session.inputSettingsDidChange?()
        let result = try item("输入源未确认，请手动检查显示器", in: delegate)
        XCTAssertFalse(result.isEnabled)
        XCTAssertFalse(result.isHidden)
        XCTAssertEqual(session.inputSelections, [0x12])
        XCTAssertEqual(session.automaticChanges, [true])
        for status in [PrimarySessionStatus.applying, .recoveryIncomplete, .restoringAndQuitting] {
            session.emit(status)
            await drainMainQueue()
            let port = try option("PC 输入 0x11（请确认端口）")
            let toggle = try option("启用自动切到 PC")
            XCTAssertFalse(port.isEnabled)
            XCTAssertFalse(toggle.isEnabled)
            try dispatch(port)
            try dispatch(toggle)
        }
        XCTAssertEqual(session.inputSelections, [0x12])
        XCTAssertEqual(session.automaticChanges, [true])
    }

    func testInputSettingsRejectUnverifiedPortEvenThroughForgedAction() throws {
        let session = ModeSession()
        session.availableModes.append(.internalOnly)
        session.inputUnavailableReason = nil
        session.inputOptions = [0x11]
        let delegate = MenuBarApplicationDelegate(controllerFactory: { session })
        delegate.startSession()
        let submenu = try XCTUnwrap(try item("自动切到 PC", in: delegate).submenu)
        let port = try XCTUnwrap(submenu.item(withTitle: "PC 输入 0x11（请确认端口）"))
        port.representedObject = NSNumber(value: 0x12)
        try dispatch(port)
        XCTAssertTrue(session.inputSelections.isEmpty)
        session.selectedPCInput = 0x12
        session.inputSettingsDidChange?()
        let toggle = try XCTUnwrap(try item("自动切到 PC", in: delegate).submenu?.item(withTitle: "启用自动切到 PC"))
        XCTAssertFalse(toggle.isEnabled)
        try dispatch(toggle)
        XCTAssertTrue(session.automaticChanges.isEmpty)
    }

    func testConnectionConfirmationRoutesRestoreAndRetryWithoutConfirmingLayout() async throws {
        for restore in [true, false] {
            let session = ConnectionSession()
            var prompts = 0
            let delegate = MenuBarApplicationDelegate(controllerFactory: { session }, confirmConnectionRecovery: {
                prompts += 1
                return true
            })
            delegate.startSession()
            session.emit(restore ? .applied : .recoveryIncomplete)
            await drainMainQueue()
            let action = try item(restore ? "恢复外接屏" : "重试恢复", in: delegate)
            try dispatch(action)
            try dispatch(action)
            session.emit(restore ? .applied : .recoveryIncomplete)
            await drainMainQueue()
            XCTAssertEqual(session.preparations.count, 1)
            XCTAssertTrue(delegate.accessibilityStatusLabel.contains("正在确认连接…"))
            XCTAssertFalse(try item("退出并恢复", in: delegate).isEnabled)
            XCTAssertFalse(try item("打开显示设置", in: delegate).isEnabled)
            try dispatch(try item("设为恢复布局", in: delegate))
            let token = try connectionToken()
            session.preparations[0](token)
            await drainConnectionPreparation()
            XCTAssertEqual(prompts, 1)
            XCTAssertEqual(session.confirmedRecoveries.map(\.id), [token.id])
            XCTAssertEqual(session.confirmations, 0)
            XCTAssertEqual(session.configurationRestores, 0)
            XCTAssertEqual(session.recoveries, 0)
            XCTAssertTrue(delegate.accessibilityStatusLabel.contains("正在恢复…"))
        }
    }

    func testCancelledConnectionConfirmationRestoresControlsAndConsumesToken() async throws {
        let session = ConnectionSession()
        let delegate = MenuBarApplicationDelegate(controllerFactory: { session }, confirmConnectionRecovery: { false })
        delegate.startSession()
        session.emit(.applied)
        await drainMainQueue()
        let restore = try item("恢复外接屏", in: delegate)
        try dispatch(restore)
        let record = try connectionRecord()
        let token = ExternalConnectionRecoveryConfirmation(record: record)
        session.preparations[0](token)
        await drainConnectionPreparation()
        XCTAssertFalse(token.consume(for: record))
        XCTAssertTrue(restore.isEnabled)
        XCTAssertTrue(try item("退出并恢复", in: delegate).isEnabled)
        XCTAssertTrue(session.confirmedRecoveries.isEmpty)
        try dispatch(restore)
        XCTAssertEqual(session.preparations.count, 2)
    }

    func testNilConnectionPreparationUsesOriginalRecoveryEntryWithoutPrompt() async throws {
        for restore in [true, false] {
            let session = ConnectionSession()
            let delegate = MenuBarApplicationDelegate(controllerFactory: { session }, confirmConnectionRecovery: {
                XCTFail("Normal recovery must not ask for connection confirmation")
                return true
            })
            delegate.startSession()
            session.emit(restore ? .applied : .recoveryIncomplete)
            await drainMainQueue()
            try dispatch(try item(restore ? "恢复外接屏" : "重试恢复", in: delegate))
            session.preparations[0](nil)
            await drainConnectionPreparation()
            XCTAssertEqual(session.configurationRestores, restore ? 1 : 0)
            XCTAssertEqual(session.recoveries, restore ? 0 : 1)
        }
    }

    func testFailedConnectionPreparationDoesNotFallThroughToOrdinaryRecovery() async throws {
        let session = ConnectionSession()
        let delegate = MenuBarApplicationDelegate(controllerFactory: { session }, confirmConnectionRecovery: {
            XCTFail("Failed preparation must not open a prompt")
            return true
        })
        delegate.startSession()
        session.emit(.applied)
        await drainMainQueue()
        let restore = try item("恢复外接屏", in: delegate)
        try dispatch(restore)
        session.preparationResults[0](.failure(RecoveryError.invalidTransition))
        await drainConnectionPreparation()
        XCTAssertEqual(session.configurationRestores, 0)
        XCTAssertEqual(session.recoveries, 0)
        XCTAssertTrue(session.confirmedRecoveries.isEmpty)
        XCTAssertTrue(restore.isEnabled)
    }

    func testDelayedConnectionPreparationRejectsChangedIntentForTokenAndNil() async throws {
        for invalidation in ["status", "owner", "termination", "mode"] {
            for returnsToken in [true, false] {
                let session = ConnectionSession()
                let replacement = ConnectionSession()
                var current = session
                let delegate = MenuBarApplicationDelegate(controllerFactory: { current }, confirmConnectionRecovery: {
                    XCTFail("Stale preparation must not open a prompt")
                    return true
                })
                delegate.startSession()
                session.emit(.applied)
                await drainMainQueue()
                try dispatch(try item("恢复外接屏", in: delegate))
                switch invalidation {
                case "status":
                    session.emit(.manualConfiguration)
                    await drainMainQueue()
                case "owner":
                    current = replacement
                    delegate.startSession()
                case "termination":
                    XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateCancel)
                default:
                    session.selectedMode = .externalPrimary
                    session.modeDidChange?()
                    session.selectedMode = .internalOnly
                    session.modeDidChange?()
                }
                let record = try connectionRecord()
                let token = ExternalConnectionRecoveryConfirmation(record: record)
                session.preparations[0](returnsToken ? token : nil)
                await drainConnectionPreparation()
                XCTAssertEqual(session.configurationRestores, 0, invalidation)
                XCTAssertEqual(session.recoveries, 0, invalidation)
                XCTAssertTrue(session.confirmedRecoveries.isEmpty, invalidation)
                if returnsToken { XCTAssertFalse(token.consume(for: record)) }
            }
        }
    }

    func testConnectionPromptRechecksIntentAfterNestedEvents() async throws {
        let session = ConnectionSession()
        var delegate: MenuBarApplicationDelegate!
        delegate = MenuBarApplicationDelegate(controllerFactory: { session }, confirmConnectionRecovery: {
            XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateCancel)
            return true
        })
        delegate.startSession()
        session.emit(.applied)
        await drainMainQueue()
        try dispatch(try item("恢复外接屏", in: delegate))
        let record = try connectionRecord()
        let token = ExternalConnectionRecoveryConfirmation(record: record)
        session.preparations[0](token)
        await drainConnectionPreparation()
        XCTAssertTrue(session.confirmedRecoveries.isEmpty)
        XCTAssertFalse(token.consume(for: record))
    }

    func testQuitRetryPreparesConnectionThenQuitsOnlyAfterRecovery() async throws {
        for quitStatus in [PrimarySessionStatus.quitFailed, .quitWaitingForDisplays] {
            let session = ConnectionSession()
            var terminationRequests = 0
            var prompts = 0
            let delegate = MenuBarApplicationDelegate(controllerFactory: { session }, requestTermination: {
                terminationRequests += 1
            }, confirmConnectionRecovery: {
                prompts += 1
                return true
            })
            delegate.startSession()
            session.emit(quitStatus)
            await drainMainQueue()
            XCTAssertEqual(prompts, 0)
            try dispatch(try item("重试恢复", in: delegate))
            XCTAssertEqual(terminationRequests, 0)
            XCTAssertEqual(session.preparations.count, 1)
            session.preparations[0](try connectionToken())
            await drainConnectionPreparation()
            XCTAssertEqual(prompts, 1)
            XCTAssertEqual(session.confirmedRecoveries.count, 1)
            XCTAssertEqual(terminationRequests, 0)
            session.emit(.manualConfiguration)
            await drainMainQueue()
            XCTAssertEqual(terminationRequests, 1)
        }
    }

    private func connectionRecord() throws -> RecoveryRecord {
        let id = UUID()
        let layout = try DisplayLayout(main: id, origins: [id: DisplayOrigin(x: 0, y: 0)])
        return try RecoveryRecord(baseline: layout, target: layout)
    }

    private func connectionToken() throws -> ExternalConnectionRecoveryConfirmation {
        ExternalConnectionRecoveryConfirmation(record: try connectionRecord())
    }

    @MainActor
    private final class ConnectionSession: ModeSession, ExternalConnectionRecoveryControlling {
        var preparations: [@Sendable (ExternalConnectionRecoveryConfirmation?) -> Void] = []
        var confirmedRecoveries: [ExternalConnectionRecoveryConfirmation] = []
        init(mode: DisplayApplicationMode = .internalOnly) {
            super.init()
            selectedMode = mode
            availableModes.append(.internalOnly)
        }
        var preparationResults: [@Sendable (Result<ExternalConnectionRecoveryConfirmation?, Error>) -> Void] = []
        func prepareConnectionRecovery(completion: @escaping @Sendable (Result<ExternalConnectionRecoveryConfirmation?, Error>) -> Void) {
            preparationResults.append(completion)
            preparations.append { completion(.success($0)) }
        }
        func recoverAfterConfirmingConnection(_ confirmation: ExternalConnectionRecoveryConfirmation) {
            confirmedRecoveries.append(confirmation)
        }
    }

    private func drainConnectionPreparation() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.common, .modalPanel]) { continuation.resume() }
        }
    }

    @MainActor
    private class ModeSession: FakeSession, DisplayModeSelecting, ExternalDisplayInputSettingsSelecting {
        var inputOptions: [UInt16] = []
        var selectedPCInput: UInt16?
        var automaticInputEnabled = false
        var inputUnavailableReason: String? = "当前连接尚未验收自动输入源切换"
        var inputResultText: String?
        var inputSettingsDidChange: (@MainActor () -> Void)?
        var inputSelections: [UInt16] = []
        var automaticChanges: [Bool] = []
        func selectPCInput(_ input: UInt16) {
            inputSelections.append(input)
            selectedPCInput = input
            inputSettingsDidChange?()
        }
        func setAutomaticInput(_ enabled: Bool) {
            automaticChanges.append(enabled)
            automaticInputEnabled = enabled
            inputSettingsDidChange?()
        }
        var availableModes: [DisplayApplicationMode] = [.externalPrimary, .externalOnly]
        var selectedMode: DisplayApplicationMode?
        var requiresExplicitActivation = false
        var modeDidChange: (@MainActor () -> Void)?
        var selections: [DisplayApplicationMode] = []
        var configurationRestores = 0
        func restoreForConfiguration() { configurationRestores += 1 }
        func selectMode(_ mode: DisplayApplicationMode) {
            selections.append(mode)
            selectedMode = mode
            requiresExplicitActivation = false
            modeDidChange?()
        }
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
    private class FakeSession: PrimaryApplicationControlling {
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
