import AppKit
import Darwin
import ExtilumeCore

@MainActor
protocol PrimaryApplicationControlling {
    func startApplication(registerEvents: Bool, recoveryOnly: Bool, onStatus: @escaping @Sendable (PrimarySessionStatus) -> Void)
    func retryApplication()
    func recoverApplication()
    func confirmCurrentConfiguration()
    func quitApplication(completion: @escaping @Sendable (Bool) -> Void)
}

extension PrimaryController: PrimaryApplicationControlling {}

@MainActor
public func runMenuBarApplication() throws {
    let applicationLease = try acquireApplicationControlLease()
    let directory = try applicationStateDirectory(arguments: Array(CommandLine.arguments.dropFirst())) {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
    }
    let controller = try DisplayModeCoordinator(directory: directory)
    let application = NSApplication.shared
    let delegate = MenuBarApplicationDelegate(controllerFactory: { controller }, developmentBuild: true)
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime((delegate, applicationLease)) { application.run() }
}

@MainActor
final class MenuBarApplicationDelegate: NSObject, NSApplicationDelegate {
    let menu = NSMenu()
    private let controllerFactory: () throws -> any PrimaryApplicationControlling
    private let requestTermination: () -> Void
    private let replyTermination: (Bool) -> Void
    private let openSettings: (URL) -> Void
    private var controller: (any PrimaryApplicationControlling)?
    private var statusItem: NSStatusItem?
    private var signals: [DispatchSourceSignal] = []
    private let fixedModeItem = NSMenuItem(title: "模式：外屏主屏", action: nil, keyEquivalent: "")
    private var modeItems: [NSMenuItem] = []
    private var statusMode: DisplayApplicationMode?
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let retryItem = NSMenuItem(title: "重试", action: nil, keyEquivalent: "")
    private let recoverItem = NSMenuItem(title: "重试恢复", action: nil, keyEquivalent: "")
    private let restoreForConfigurationItem = NSMenuItem(title: "恢复双屏以调整排列", action: nil, keyEquivalent: "")
    private let confirmItem = NSMenuItem(title: "设为恢复布局", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "打开显示设置", action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "退出并恢复", action: nil, keyEquivalent: "q")
    private var status: PrimarySessionStatus = .waiting
    private var recoveryInProgress = false
    private var confirmationInProgress = false
    private var terminationPending = false
    private var quitAfterRecovery = false

    init(
        controllerFactory: @escaping () throws -> any PrimaryApplicationControlling,
        developmentBuild: Bool = false,
        requestTermination: @escaping () -> Void = { NSApplication.shared.terminate(nil) },
        replyTermination: @escaping (Bool) -> Void = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) },
        openSettings: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.controllerFactory = controllerFactory
        self.requestTermination = requestTermination
        self.replyTermination = replyTermination
        self.openSettings = openSettings
        super.init()
        menu.autoenablesItems = false
        fixedModeItem.isEnabled = false
        stateItem.isEnabled = false
        if developmentBuild {
            let developmentItem = NSMenuItem(title: "开发版 · 仅外屏尚未准入日用", action: nil, keyEquivalent: "")
            developmentItem.isEnabled = false
            menu.addItem(developmentItem)
        }
        menu.addItem(fixedModeItem)
        menu.addItem(stateItem)
        menu.addItem(.separator())
        retryItem.target = self
        retryItem.action = #selector(retryApplication)
        menu.addItem(retryItem)
        recoverItem.target = self
        recoverItem.action = #selector(retryRecovery)
        menu.addItem(recoverItem)
        restoreForConfigurationItem.target = self
        restoreForConfigurationItem.action = #selector(restoreForConfiguration)
        confirmItem.target = self
        confirmItem.action = #selector(confirmCurrentConfiguration)
        menu.addItem(confirmItem)
        settingsItem.action = #selector(openDisplaySettings)
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        quitItem.target = self
        quitItem.action = #selector(quitApplication)
        menu.addItem(quitItem)
        render()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = menuBarIcon()
        item.menu = menu
        statusItem = item
        render()
        let application = NSApplication.shared
        let policy: String
        switch application.activationPolicy() {
        case .regular: policy = "regular"
        case .accessory: policy = "accessory"
        case .prohibited: policy = "prohibited"
        @unknown default: policy = "unknown"
        }
        print("菜单栏运行：入口=\(item.isVisible ? "是" : "否")；窗口数=\(application.windows.count)；策略=\(policy)")
        print("窗口类别：\(application.windows.map { String(describing: type(of: $0)) }.joined(separator: ","))")
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                DispatchQueue.main.async { [weak self] in
                    print("收到正常停止信号")
                    self?.requestTermination()
                }
            }
            signals.append(source)
            source.resume()
        }
        startSession()
    }

    func startSession() {
        startController(recoveryOnly: false)
    }

    private func startController(recoveryOnly: Bool) {
        do {
            let controller = try controllerFactory()
            self.controller = controller
            if let selector = controller as? any DisplayModeSelecting {
                if modeItems.isEmpty {
                    menu.removeItem(fixedModeItem)
                    menu.insertItem(restoreForConfigurationItem, at: menu.index(of: confirmItem))
                    for (index, mode) in DisplayApplicationMode.allCases.enumerated() {
                        let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = mode.rawValue
                        menu.insertItem(item, at: index)
                        modeItems.append(item)
                    }
                }
                selector.modeDidChange = { [weak self] in self?.render() }
            }
            render()
            controller.startApplication(registerEvents: true, recoveryOnly: recoveryOnly) { [weak self] status in
                DispatchQueue.main.async { [weak self] in self?.receive(status) }
            }
        } catch {
            recoveryInProgress = false
            status = quitAfterRecovery ? .quitFailed : .recoveryIncomplete
            quitAfterRecovery = false
            render()
        }
    }

    private func receive(_ newStatus: PrimarySessionStatus) {
        print("会话状态：\(newStatus.text)")
        guard !terminationPending || newStatus == .quitWaitingForDisplays else { return }
        status = newStatus
        statusMode = modeSelector?.selectedMode
        if newStatus == .applying {
            render()
            return
        }
        recoveryInProgress = false
        confirmationInProgress = false
        if quitAfterRecovery {
            quitAfterRecovery = false
            if !newStatus.needsRecovery {
                requestTermination()
                return
            }
            status = .quitFailed
        }
        render()
    }

    private var modeSelector: (any DisplayModeSelecting)? { controller as? any DisplayModeSelecting }

    private var canSelectMode: Bool {
        controller != nil && !recoveryInProgress && !confirmationInProgress && !terminationPending
            && !status.needsRecovery && status != .applying && status != .restoringAndQuitting
            && status != .manualConfigurationForQuit
    }

    private var canRestoreForConfiguration: Bool {
        modeSelector?.selectedMode == .externalOnly && status == .applied
            && statusMode == .externalOnly && modeSelector?.requiresExplicitActivation == false && canSelectMode
    }

    private var statusText: String {
        guard let selector = modeSelector else { return status.text }
        if status.needsRecovery || status == .restoringAndQuitting || status == .manualConfigurationForQuit {
            return status.text
        }
        guard let mode = selector.selectedMode else { return "请选择显示模式" }
        if selector.requiresExplicitActivation { return "已选择仅外屏，等待点击模式应用" }
        if status == .applied && statusMode != mode { return "已选择模式，尚未应用" }
        if mode == .externalOnly {
            switch status {
            case .applying: return "正在停用内屏…"
            case .applied: return "仅外屏已生效"
            case .manualConfiguration: return "双屏已恢复，可调整或确认排列"
            default: break
            }
        }
        return status.text
    }

    var accessibilityStatusLabel: String {
        let mode = modeSelector.map { $0.selectedMode?.title ?? "未选择" } ?? "外屏主屏"
        return "Extilume，模式：\(mode)，\(stateItem.title)"
    }

    private func render() {
        let busy = recoveryInProgress || confirmationInProgress || terminationPending
        let text = confirmationInProgress ? "正在确认排列…" : (recoveryInProgress ? "正在恢复…" : statusText)
        stateItem.title = text
        let externalOnly = modeSelector?.selectedMode == .externalOnly
        let modeIsApplied = status == .applied && statusMode == modeSelector?.selectedMode
            && modeSelector?.requiresExplicitActivation == false && !busy
        for item in modeItems {
            item.state = modeIsApplied && item.representedObject as? String == statusMode?.rawValue ? .on : .off
            item.isEnabled = canSelectMode
        }
        retryItem.title = status == .manualConfiguration ? (externalOnly ? "应用仅外屏" : "设为外屏主屏") : "重试"
        retryItem.isHidden = !status.canRetryApplication
        retryItem.isEnabled = status.canRetryApplication && !busy
        recoverItem.isHidden = !status.canRetryRecovery
        recoverItem.isEnabled = status.canRetryRecovery && !busy
        let recoveryHint = status == .quitWaitingForDisplays
            ? "请打开笔记本上盖或接回原外接显示器，再点“重试恢复”以恢复并退出。" : nil
        stateItem.toolTip = recoveryHint
        recoverItem.toolTip = recoveryHint
        restoreForConfigurationItem.isHidden = !canRestoreForConfiguration
        restoreForConfigurationItem.isEnabled = canRestoreForConfiguration
        restoreForConfigurationItem.toolTip = "先恢复双屏，再调整排列并设为恢复布局；不会自动重新停用内屏。"
        let canConfirm = (status.canConfirmConfiguration && !(externalOnly && status == .quitFailed))
            || (externalOnly && status == .manualConfiguration)
        confirmItem.isHidden = !canConfirm
        confirmItem.isEnabled = canConfirm && controller != nil && !busy
        confirmItem.toolTip = status == .quitFailed
            ? "将当前排列设为退出时的恢复目标，不切换主屏；保存后请再次点“退出并恢复”。"
            : "将当前排列设为退出时的恢复目标，不会立即切换主屏。保存后可点“设为外屏主屏”，也可等待下一次连接或唤醒。若已请求退出，则不再自动接管。"
        if externalOnly {
            confirmItem.toolTip = status == .quitFailed
                ? "将当前排列设为退出时的恢复目标，不停用内屏；保存后请再次点“退出并恢复”。"
                : "将当前排列设为退出时的恢复目标，不会立即停用内屏。保存后请点“应用仅外屏”或再次点击已选模式。"
        }
        settingsItem.isEnabled = !confirmationInProgress
        quitItem.isEnabled = status.canQuit && !busy
        statusItem?.button?.setAccessibilityLabel(accessibilityStatusLabel)
        statusItem?.button?.toolTip = "Extilume：\(text)"
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard canSelectMode, let selector = modeSelector,
              let rawValue = sender.representedObject as? String,
              let mode = DisplayApplicationMode(rawValue: rawValue) else { return }
        status = .applying
        render()
        selector.selectMode(mode)
        render()
    }

    @objc private func restoreForConfiguration() {
        guard canRestoreForConfiguration, let selector = modeSelector else { return }
        recoveryInProgress = true
        render()
        selector.restoreForConfiguration()
    }

    @objc private func retryApplication() {
        guard status.canRetryApplication, !recoveryInProgress, !confirmationInProgress, !terminationPending,
              let controller else { return }
        status = .applying
        render()
        controller.retryApplication()
    }

    @objc private func retryRecovery() {
        guard status.canRetryRecovery, !recoveryInProgress, !confirmationInProgress, !terminationPending else { return }
        let retryQuit = status == .quitFailed || status == .quitWaitingForDisplays
        if retryQuit, controller != nil {
            requestTermination()
            return
        }
        quitAfterRecovery = retryQuit
        recoveryInProgress = true
        render()
        if let controller {
            controller.recoverApplication()
        } else {
            startController(recoveryOnly: true)
        }
    }

    @objc private func openDisplaySettings() {
        guard !confirmationInProgress else { return }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") else { return }
        openSettings(url)
    }

    @objc private func confirmCurrentConfiguration() {
        let canConfirm = (status.canConfirmConfiguration
            && !(modeSelector?.selectedMode == .externalOnly && status == .quitFailed))
            || (modeSelector?.selectedMode == .externalOnly && status == .manualConfiguration)
        guard canConfirm, !recoveryInProgress, !confirmationInProgress,
              !terminationPending, let controller else { return }
        confirmationInProgress = true
        render()
        controller.confirmCurrentConfiguration()
    }

    @objc private func quitApplication() {
        guard status.canQuit, !recoveryInProgress, !confirmationInProgress, !terminationPending else { return }
        requestTermination()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        print("处理正常退出请求")
        guard !terminationPending else { return .terminateLater }
        guard !recoveryInProgress, !confirmationInProgress else { return .terminateCancel }
        guard let controller else {
            status = .quitFailed
            render()
            return .terminateCancel
        }
        terminationPending = true
        status = .restoringAndQuitting
        render()
        controller.quitApplication { [weak self] restored in
            // terminateLater 的嵌套事件循环不能再次排空当前主队列。
            RunLoop.main.perform(inModes: [.common, .modalPanel]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.terminationPending = false
                    if !restored {
                        if self.status != .quitWaitingForDisplays {
                            self.status = .quitFailed
                        }
                        self.render()
                    }
                    print(restored ? "退出恢复已确认" : "退出恢复未完成")
                    self.replyTermination(restored)
                }
            }
        }
        return .terminateLater
    }
}
