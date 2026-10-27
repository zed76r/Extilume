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
    let launchOptions = try applicationLaunchOptions(arguments: Array(CommandLine.arguments.dropFirst())) {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
    }
    let controller: DisplayModeCoordinator
    if launchOptions.verifiesExternalHandoff {
        let launchPreferences = try externalHandoffLaunchPreferences(for: launchOptions.stateDirectory)
        controller = try DisplayModeCoordinator(
            directory: launchOptions.stateDirectory,
            preferences: launchPreferences.preferences,
            availableModes: [.externalPrimary, .internalOnly],
            inputSettings: ExternalDisplayInputSettings(defaults: launchPreferences.defaults)
        )
    } else {
        controller = try DisplayModeCoordinator(directory: launchOptions.stateDirectory)
    }
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
    private let confirmConnectionRecovery: () -> Bool
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
    private let automaticInputItem = NSMenuItem(title: "自动切到 PC", action: nil, keyEquivalent: "")
    private let inputResultItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "打开显示设置", action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "退出并恢复", action: nil, keyEquivalent: "q")
    private var status: PrimarySessionStatus = .waiting
    private var recoveryInProgress = false
    private var confirmationInProgress = false
    private var connectionRecoveryRequest: UUID?
    private var connectionRecoveryConfirmation: ExternalConnectionRecoveryConfirmation?
    private var controllerGeneration = UUID()
    private var terminationPending = false
    private var quitAfterRecovery = false

    init(
        controllerFactory: @escaping () throws -> any PrimaryApplicationControlling,
        developmentBuild: Bool = false,
        requestTermination: @escaping () -> Void = { NSApplication.shared.terminate(nil) },
        replyTermination: @escaping (Bool) -> Void = { NSApplication.shared.reply(toApplicationShouldTerminate: $0) },
        openSettings: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
        confirmConnectionRecovery: @escaping () -> Bool = {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "确认 HDMI 物理连接未改变"
            alert.informativeText = "从本次交接开始，你是否没有拔插 HDMI、换接口或更换显示器？仅在显示器上切换 PC / Mac 输入源不算改变物理连接。\n\n确认后将尝试恢复 Mac 的 HDMI 输出；恢复后请将显示器切到 Mac。此确认仅用于这一次恢复，不会确认或保存恢复布局。若不确定，请取消。"
            alert.addButton(withTitle: "取消")
            alert.addButton(withTitle: "连接未变，恢复外接屏")
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].keyEquivalent = ""
            return alert.runModal() == .alertSecondButtonReturn
        }
    ) {
        self.controllerFactory = controllerFactory
        self.requestTermination = requestTermination
        self.replyTermination = replyTermination
        self.openSettings = openSettings
        self.confirmConnectionRecovery = confirmConnectionRecovery
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
        menu.addItem(automaticInputItem)
        inputResultItem.isEnabled = false
        menu.addItem(inputResultItem)
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
        cancelConnectionRecovery()
        controllerGeneration = UUID()
        let generation = controllerGeneration
        do {
            let controller = try controllerFactory()
            self.controller = controller
            if let selector = controller as? any DisplayModeSelecting {
                if modeItems.isEmpty {
                    menu.removeItem(fixedModeItem)
                    menu.insertItem(restoreForConfigurationItem, at: menu.index(of: confirmItem))
                    for (index, mode) in selector.availableModes.enumerated() {
                        let item = NSMenuItem(title: mode.title, action: #selector(selectMode(_:)), keyEquivalent: "")
                        item.target = self
                        item.representedObject = mode.rawValue
                        menu.insertItem(item, at: index)
                        modeItems.append(item)
                    }
                }
                selector.modeDidChange = { [weak self] in
                    guard let self else { return }
                    if self.modeSelector?.selectedMode != .internalOnly { self.cancelConnectionRecovery() }
                    self.render()
                }
            }
            (controller as? any ExternalDisplayInputSettingsSelecting)?.inputSettingsDidChange = { [weak self] in
                self?.render()
            }
            render()
            controller.startApplication(registerEvents: true, recoveryOnly: recoveryOnly) { [weak self] status in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.controllerGeneration == generation else { return }
                    self.receive(status)
                }
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
        if connectionRecoveryRequest != nil {
            if newStatus == status {
                render()
                return
            }
            cancelConnectionRecovery()
        }
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
        (modeSelector?.selectedMode == .externalOnly || modeSelector?.selectedMode == .internalOnly) && status == .applied
            && statusMode == modeSelector?.selectedMode && modeSelector?.requiresExplicitActivation == false && canSelectMode
    }

    private var statusText: String {
        guard let selector = modeSelector else { return status.text }
        if status.needsRecovery || status == .restoringAndQuitting || status == .manualConfigurationForQuit {
            return status.text
        }
        guard let mode = selector.selectedMode else { return "请选择显示模式" }
        if selector.requiresExplicitActivation {
            return mode == .internalOnly ? "已选择仅内屏，等待点击模式应用" : "已选择仅外屏，等待点击模式应用"
        }
        if status == .applied && statusMode != mode { return "已选择模式，尚未应用" }
        if mode == .externalOnly {
            switch status {
            case .applying: return "正在停用内屏…"
            case .applied: return "仅外屏已生效"
            case .manualConfiguration: return "双屏已恢复，可调整或确认排列"
            default: break
            }
        }
        if mode == .internalOnly {
            switch status {
            case .applying: return "正在停用外接屏…"
            case .applied: return "外接屏已停用，请切换显示器到 PC"
            case .manualConfiguration: return "外接屏已恢复，请切换显示器到 Mac"
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
        let text = connectionRecoveryRequest != nil ? "正在确认连接…" : confirmationInProgress ? "正在确认排列…" : (recoveryInProgress ? "正在恢复…" : statusText)
        stateItem.title = text
        let externalOnly = modeSelector?.selectedMode == .externalOnly
        let internalOnly = modeSelector?.selectedMode == .internalOnly
        let modeIsApplied = status == .applied && statusMode == modeSelector?.selectedMode
            && modeSelector?.requiresExplicitActivation == false && !busy
        for item in modeItems {
            item.state = modeIsApplied && item.representedObject as? String == statusMode?.rawValue ? .on : .off
            item.isEnabled = canSelectMode
        }
        retryItem.title = status == .manualConfiguration ? (internalOnly ? "应用仅内屏" : (externalOnly ? "应用仅外屏" : "设为外屏主屏")) : "重试"
        retryItem.isHidden = !status.canRetryApplication
        retryItem.isEnabled = status.canRetryApplication && !busy
        recoverItem.isHidden = !status.canRetryRecovery
        recoverItem.isEnabled = status.canRetryRecovery && !busy
        let recoveryHint = status == .quitWaitingForDisplays
            ? "请打开笔记本上盖或接回原外接显示器，再点“重试恢复”以恢复并退出。" : nil
        stateItem.toolTip = recoveryHint
        recoverItem.toolTip = recoveryHint
        restoreForConfigurationItem.title = internalOnly ? "恢复外接屏" : "恢复双屏以调整排列"
        restoreForConfigurationItem.isHidden = !canRestoreForConfiguration
        restoreForConfigurationItem.isEnabled = canRestoreForConfiguration
        restoreForConfigurationItem.toolTip = internalOnly
            ? "恢复 Mac 外屏配置后，请手动切换显示器到 Mac；不会自动重新停用外接屏。"
            : "先恢复双屏，再调整排列并设为恢复布局；不会自动重新停用内屏。"
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
        if internalOnly {
            confirmItem.toolTip = "独立核对完整双屏后，将你确认的排列设为恢复布局；不会重新停用外屏。"
        }
        renderInputSettings()
        settingsItem.isEnabled = !confirmationInProgress && connectionRecoveryRequest == nil
        quitItem.isEnabled = status.canQuit && !busy
        statusItem?.button?.setAccessibilityLabel(accessibilityStatusLabel)
        statusItem?.button?.toolTip = "Extilume：\(text)"
    }

    private var inputSettings: (any ExternalDisplayInputSettingsSelecting)? {
        controller as? any ExternalDisplayInputSettingsSelecting
    }

    private var showsInputSettings: Bool {
        modeSelector?.availableModes.contains(.internalOnly) == true || modeSelector?.selectedMode == .internalOnly
    }

    private var canEditInputSettings: Bool {
        showsInputSettings && canSelectMode && inputSettings?.inputUnavailableReason == nil
            && inputSettings?.inputOptions.isEmpty == false
    }

    private func renderInputSettings() {
        automaticInputItem.isHidden = !showsInputSettings
        inputResultItem.isHidden = !showsInputSettings || inputSettings?.inputResultText == nil
        inputResultItem.title = inputSettings?.inputResultText ?? ""
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        automaticInputItem.submenu = submenu
        automaticInputItem.isEnabled = showsInputSettings
        guard showsInputSettings else { return }
        if let reason = inputSettings?.inputUnavailableReason {
            let reasonItem = NSMenuItem(title: reason, action: nil, keyEquivalent: "")
            reasonItem.isEnabled = false
            submenu.addItem(reasonItem)
        }
        for input in inputSettings?.inputOptions ?? [] {
            let option = NSMenuItem(
                title: String(format: "PC 输入 0x%02X（请确认端口）", Int(input)),
                action: #selector(selectPCInput(_:)), keyEquivalent: ""
            )
            option.target = self
            option.representedObject = NSNumber(value: input)
            option.state = inputSettings?.selectedPCInput == input ? .on : .off
            option.isEnabled = canEditInputSettings
            submenu.addItem(option)
        }
        let toggle = NSMenuItem(title: "启用自动切到 PC", action: #selector(toggleAutomaticInput), keyEquivalent: "")
        toggle.target = self
        toggle.state = inputSettings?.automaticInputEnabled == true ? .on : .off
        if let settings = inputSettings, let input = settings.selectedPCInput {
            toggle.isEnabled = canEditInputSettings && settings.inputOptions.contains(input)
        } else {
            toggle.isEnabled = false
        }
        toggle.toolTip = "只在显式交接时尝试切换；请保留显示器实体输入按钮。输入读回不代表 PC 画面已确认。"
        submenu.addItem(toggle)
    }

    @objc private func selectPCInput(_ sender: NSMenuItem) {
        guard canEditInputSettings, let settings = inputSettings,
              let number = sender.representedObject as? NSNumber,
              let input = UInt16(exactly: number.intValue), settings.inputOptions.contains(input) else { return }
        settings.selectPCInput(input)
        render()
    }

    @objc private func toggleAutomaticInput() {
        guard canEditInputSettings, let settings = inputSettings,
              let input = settings.selectedPCInput, settings.inputOptions.contains(input) else { return }
        settings.setAutomaticInput(!settings.automaticInputEnabled)
        render()
    }

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard canSelectMode, let selector = modeSelector,
              let rawValue = sender.representedObject as? String,
              let mode = DisplayApplicationMode(rawValue: rawValue),
              selector.availableModes.contains(mode) else { return }
        status = .applying
        render()
        selector.selectMode(mode)
        render()
    }

    @objc private func restoreForConfiguration() {
        guard canRestoreForConfiguration, let selector = modeSelector else { return }
        beginExplicitRecovery { selector.restoreForConfiguration() }
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
        if retryQuit, controller != nil, connectionRecoveryController == nil {
            requestTermination()
            return
        }
        beginExplicitRecovery(quitAfterRecovery: retryQuit) { [self] in
            if let controller {
                controller.recoverApplication()
            } else {
                startController(recoveryOnly: true)
            }
        }
    }

    private var connectionRecoveryController: (any ExternalConnectionRecoveryControlling)? {
        guard modeSelector?.selectedMode == .internalOnly else { return nil }
        return controller as? any ExternalConnectionRecoveryControlling
    }

    private func cancelConnectionRecovery() {
        guard connectionRecoveryRequest != nil else { return }
        connectionRecoveryConfirmation?.cancel()
        connectionRecoveryConfirmation = nil
        connectionRecoveryRequest = nil
        recoveryInProgress = false
    }

    private func beginExplicitRecovery(quitAfterRecovery: Bool = false, ordinaryRecovery: @escaping @MainActor () -> Void) {
        recoveryInProgress = true
        guard let owner = connectionRecoveryController else {
            self.quitAfterRecovery = quitAfterRecovery
            render()
            ordinaryRecovery()
            return
        }
        let request = UUID()
        connectionRecoveryRequest = request
        render()
        owner.prepareConnectionRecovery { [weak self] result in
            RunLoop.main.perform(inModes: [.common, .modalPanel]) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.connectionRecoveryRequest == request,
                          self.connectionRecoveryController === owner, !self.terminationPending else {
                        if case .success(let confirmation) = result { confirmation?.cancel() }
                        return
                    }
                    let confirmation: ExternalConnectionRecoveryConfirmation?
                    do { confirmation = try result.get() }
                    catch {
                        self.cancelConnectionRecovery()
                        self.render()
                        return
                    }
                    self.connectionRecoveryConfirmation = confirmation
                    let accepted = confirmation == nil || self.confirmConnectionRecovery()
                    // NSAlert runs a nested event loop; recheck the intent after the user's answer.
                    guard self.connectionRecoveryRequest == request,
                          self.connectionRecoveryController === owner, !self.terminationPending else {
                        confirmation?.cancel()
                        return
                    }
                    self.connectionRecoveryRequest = nil
                    self.connectionRecoveryConfirmation = nil
                    guard accepted else {
                        confirmation?.cancel()
                        self.recoveryInProgress = false
                        self.render()
                        return
                    }
                    self.quitAfterRecovery = quitAfterRecovery
                    self.render()
                    if let confirmation {
                        owner.recoverAfterConfirmingConnection(confirmation)
                    } else {
                        ordinaryRecovery()
                    }
                }
            }
        }
    }

    @objc private func openDisplaySettings() {
        guard !confirmationInProgress, connectionRecoveryRequest == nil else { return }
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
        if connectionRecoveryRequest != nil {
            cancelConnectionRecovery()
            render()
            return .terminateCancel
        }
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
