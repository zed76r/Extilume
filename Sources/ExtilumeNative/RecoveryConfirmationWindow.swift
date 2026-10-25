import AppKit

@MainActor
final class RecoveryConfirmationWindowController: NSWindowController, NSWindowDelegate {
    let verificationView = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
    let confirmButton = NSButton(title: "内屏和桌面已恢复可用", target: nil, action: nil)
    let endButton = NSButton(title: "关闭", target: nil, action: nil)
    let statusLabel = NSTextField(wrappingLabelWithString: "等待人工确认 · 尚未记录")
    private(set) var recorded = false
    private let record: () throws -> Void
    private let finish: () -> Void
    private var attempted = false
    private var finished = false

    init(record: @escaping () throws -> Void, finish: @escaping () -> Void) {
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
        window.title = "恢复可用人工确认"
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
        _ = label("恢复可用人工确认", font: .systemFont(ofSize: 21, weight: .semibold))
        _ = label("请在实际看到内屏及本次应恢复的桌面均可正常操作后，点击下方按钮。点击时记录一次人工确认时刻，并关闭窗口。")
        let disclosure = label("此记录仅代表人工观察；显示配置仍需独立核验，故障恢复耗时仍需单独评估。")
        disclosure.textColor = .secondaryLabelColor
        confirmButton.bezelStyle = .rounded
        confirmButton.target = self
        confirmButton.action = #selector(confirmRecovery)
        confirmButton.keyEquivalent = ""
        confirmButton.setAccessibilityHelp("确认内屏及本次应恢复的桌面均可正常操作后，记录当前人工确认时刻。")
        stack.addArrangedSubview(confirmButton)
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        stack.addArrangedSubview(statusLabel)
        statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        endButton.bezelStyle = .rounded
        endButton.target = self
        endButton.action = #selector(endRecording)
        stack.addArrangedSubview(endButton)
    }

    @objc private func confirmRecovery() {
        guard !attempted, !finished else { return }
        attempted = true
        confirmButton.isEnabled = false
        verificationView.window?.makeFirstResponder(nil)
        do {
            try record()
            recorded = true
            statusLabel.stringValue = "已记录人工确认时刻"
            endRecording()
        } catch {
            statusLabel.stringValue = "记录失败，无法再次确认。请关闭窗口并检查本次结果。"
            NSAccessibility.post(element: statusLabel, notification: .valueChanged)
        }
    }

    @objc private func endRecording() {
        finishOnce()
        verificationView.window?.close()
    }

    func windowWillClose(_ notification: Notification) { finishOnce() }

    private func finishOnce() {
        guard !finished else { return }
        finished = true
        confirmButton.isEnabled = false
        finish()
    }
}
