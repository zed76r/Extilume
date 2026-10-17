import AppKit

@MainActor
final class ConnectionTimingWindowController: NSWindowController, NSWindowDelegate {
    let verificationView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 660))
    private(set) var actionButtons: [NSButton] = []
    let statusLabel = NSTextField(wrappingLabelWithString: "尚未开始 · 请先确认 HDMI 仍连接")
    let endButton = NSButton(title: "结束记录", target: nil, action: nil)
    private let record: (ConnectionTimingAction) throws -> Void
    private let finish: () -> Void
    private let actions: [ConnectionTimingAction] = [.armUnplug, .confirmUnplug, .armReconnect, .confirmReconnect]
    private var nextStep = 0
    private var stopped = false
    private var finished = false

    init(record: @escaping (ConnectionTimingAction) throws -> Void, finish: @escaping () -> Void) {
        self.record = record
        self.finish = finish
        super.init(window: nil)
        buildView()
    }

    required init?(coder: NSCoder) { nil }

    override func showWindow(_ sender: Any?) {
        if window == nil { loadWindow() }
        super.showWindow(sender)
    }

    override func loadWindow() {
        let window = NSWindow(contentRect: verificationView.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "HDMI 拔插人工标记"
        window.isReleasedWhenClosed = false
        window.contentView = verificationView
        window.delegate = self
        self.window = window
    }

    private func buildView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        verificationView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: verificationView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: verificationView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: verificationView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: verificationView.bottomAnchor, constant: -24)
        ])
        func label(_ text: String, font: NSFont = .systemFont(ofSize: 13)) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = font
            stack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            return field
        }
        _ = label("HDMI 拔插人工标记", font: .systemFont(ofSize: 21, weight: .semibold))
        _ = label("按顺序记录准备与人工确认时刻。请先阅读每一步，再执行对应的物理操作。窗口不会自动开始流程。")
        _ = label("开始前：将此窗口移到内屏桌面，并确认本轮只读观察器均已就绪，再点击第一步。")
        let disclosure = label("仅记录人工标记，不证明物理设备身份或恢复成功，也不授权停用内屏；此窗口不写入显示设置。")
        disclosure.textColor = .secondaryLabelColor

        let steps = [
            ("1 · 准备拔出", "仅在 HDMI 仍连接时点击；记录成功后再拔出。", "HDMI 仍连接，准备拔出"),
            ("2 · 确认拔出后可用", "拔出 HDMI 后，确认内屏桌面已可操作，再点击。", "已拔出，内屏桌面可用"),
            ("3 · 准备重连", "仅在 HDMI 仍断开时点击；记录成功后再重新连接。", "HDMI 仍断开，准备重连"),
            ("4 · 确认重连后可用", "重新连接 HDMI 后，确认内外屏桌面均可操作，再点击。", "已重连，两个桌面均可用")
        ]
        for (index, step) in steps.enumerated() {
            let row = NSStackView()
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 5
            let heading = NSTextField(labelWithString: step.0)
            heading.font = .systemFont(ofSize: 13, weight: .semibold)
            row.addArrangedSubview(heading)
            let detail = NSTextField(wrappingLabelWithString: step.1)
            detail.font = .systemFont(ofSize: 12)
            detail.textColor = .secondaryLabelColor
            row.addArrangedSubview(detail)
            let button = NSButton(title: step.2, target: self, action: #selector(mark(_:)))
            button.bezelStyle = .rounded
            button.tag = index
            button.keyEquivalent = ""
            button.isEnabled = index == 0
            button.setAccessibilityHelp(step.1)
            row.addArrangedSubview(button)
            actionButtons.append(button)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            detail.widthAnchor.constraint(equalTo: row.widthAnchor).isActive = true
        }
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        endButton.bezelStyle = .rounded
        endButton.target = self
        endButton.action = #selector(endRecording)
        stack.addArrangedSubview(endButton)
    }

    @objc private func mark(_ sender: NSButton) {
        guard !stopped, !finished, nextStep < actions.count,
              sender === actionButtons[nextStep], sender.isEnabled else { return }
        // Each phase keeps its own button; keyboard focus never advances to the next physical action.
        sender.isEnabled = false
        verificationView.window?.makeFirstResponder(nil)
        do {
            try record(actions[nextStep])
            nextStep += 1
            let messages = [
                "已记录准备拔出 · 现在可拔出 HDMI，再确认内屏可用",
                "已记录内屏可用 · 保持 HDMI 断开，准备下一步",
                "已记录准备重连 · 现在可连接 HDMI，再确认两个桌面可用",
                "四个标记已记录 · 可结束记录；物理恢复仍需独立验收"
            ]
            statusLabel.stringValue = messages[nextStep - 1]
            if nextStep < actionButtons.count { actionButtons[nextStep].isEnabled = true }
        } catch {
            stopped = true
            statusLabel.stringValue = "记录失败，已停止后续标记。请结束记录并检查本次结果。"
        }
        NSAccessibility.post(element: statusLabel, notification: .valueChanged)
    }

    @objc private func endRecording() {
        finishOnce()
        verificationView.window?.close()
    }

    func windowWillClose(_ notification: Notification) { finishOnce() }

    private func finishOnce() {
        guard !finished else { return }
        finished = true
        actionButtons.forEach { $0.isEnabled = false }
        finish()
    }
}
