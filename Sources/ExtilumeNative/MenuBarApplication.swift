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
    let directory = try applicationStateDirectory(arguments: Array(CommandLine.arguments.dropFirst())) {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
    }
    let controller = try PrimaryController(directory: directory)
    let application = NSApplication.shared
    let delegate = MenuBarApplicationDelegate(controllerFactory: { controller })
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { application.run() }
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
    private let stateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let retryItem = NSMenuItem(title: "重试", action: nil, keyEquivalent: "")
    private let recoverItem = NSMenuItem(title: "重试恢复", action: nil, keyEquivalent: "")
    private let confirmItem = NSMenuItem(title: "保留当前配置", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "打开显示设置", action: nil, keyEquivalent: "")
    private let quitItem = NSMenuItem(title: "退出并恢复", action: nil, keyEquivalent: "q")
    private var status: PrimarySessionStatus = .waiting
    private var recoveryInProgress = false
    private var confirmationInProgress = false
    private var terminationPending = false
    private var quitAfterRecovery = false

    init(
        controllerFactory: @escaping () throws -> any PrimaryApplicationControlling,
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
        let mode = NSMenuItem(title: "模式：外屏主屏", action: nil, keyEquivalent: "")
        mode.isEnabled = false
        stateItem.isEnabled = false
        menu.addItem(mode)
        menu.addItem(stateItem)
        menu.addItem(.separator())
        retryItem.target = self
        retryItem.action = #selector(retryApplication)
        menu.addItem(retryItem)
        recoverItem.target = self
        recoverItem.action = #selector(retryRecovery)
        menu.addItem(recoverItem)
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
        guard !terminationPending else { return }
        status = newStatus
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

    private func render() {
        let busy = recoveryInProgress || confirmationInProgress || terminationPending
        let text = confirmationInProgress ? "正在保留当前配置…" : (recoveryInProgress ? "正在恢复…" : status.text)
        stateItem.title = text
        retryItem.isHidden = !status.canRetryApplication
        retryItem.isEnabled = status.canRetryApplication && !busy
        recoverItem.isHidden = !status.canRetryRecovery
        recoverItem.isEnabled = status.canRetryRecovery && !busy
        confirmItem.isHidden = !status.canConfirmConfiguration
        confirmItem.isEnabled = status.canConfirmConfiguration && controller != nil && !busy
        confirmItem.toolTip = status == .quitFailed
            ? "仅保存当前配置作为恢复目标；不会恢复自动接管，请再次退出并恢复。"
            : "仅保存当前配置作为恢复目标；下一次连接或唤醒时才重新应用外屏主屏。若已请求退出，则不再自动接管。"
        settingsItem.isEnabled = !confirmationInProgress
        quitItem.isEnabled = status.canQuit && !busy
        statusItem?.button?.setAccessibilityLabel("Extilume，模式：外屏主屏，\(text)")
        statusItem?.button?.toolTip = "Extilume：\(text)"
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
        if status == .quitFailed, controller != nil {
            requestTermination()
            return
        }
        quitAfterRecovery = status == .quitFailed
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
        guard status.canConfirmConfiguration, !recoveryInProgress, !confirmationInProgress,
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
                        self.status = .quitFailed
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
