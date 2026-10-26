import ExtilumeCore
import Foundation

@MainActor
protocol ExternalDisplayInputSettingsSelecting: AnyObject {
    var inputOptions: [UInt16] { get }
    var selectedPCInput: UInt16? { get }
    var automaticInputEnabled: Bool { get }
    var inputUnavailableReason: String? { get }
    var inputResultText: String? { get }
    var inputSettingsDidChange: (@MainActor () -> Void)? { get set }
    func selectPCInput(_ input: UInt16)
    func setAutomaticInput(_ enabled: Bool)
}

@MainActor
final class ExternalDisplayInputSettings: ExternalDisplayInputSettingsSelecting {
    private enum Gate {
        case available(ExternalDisplayInputCapabilities, String)
        case unavailable(String)
    }

    private let defaults: UserDefaults
    private let capabilities: ExternalDisplayInputCapabilities?
    private let inputController: any ExternalDisplayInputControlling
    private let synchronizeDefaults: () -> Bool
    private var persistenceFailed = false
    private var resultText: String?

    var inputSettingsDidChange: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard,
         capabilities: ExternalDisplayInputCapabilities? = nil,
         inputController: any ExternalDisplayInputControlling = ExternalDisplayInputController(),
         synchronize: (() -> Bool)? = nil) {
        self.defaults = defaults
        self.capabilities = capabilities
        self.inputController = inputController
        synchronizeDefaults = synchronize ?? { defaults.synchronize() }
    }

    var inputOptions: [UInt16] {
        guard case .available(let capabilities, _) = gate else { return [] }
        return capabilities.inputValues.sorted()
    }

    var selectedPCInput: UInt16? {
        guard case .available(let capabilities, let prefix) = gate else { return nil }
        return savedInput(for: capabilities, prefix: prefix)
    }

    var automaticInputEnabled: Bool {
        guard case .available(let capabilities, let prefix) = gate,
              savedInput(for: capabilities, prefix: prefix) != nil else { return false }
        return defaults.string(forKey: automaticKey(prefix)) == "true"
    }

    var inputUnavailableReason: String? {
        guard case .unavailable(let reason) = gate else { return nil }
        return reason
    }

    var inputResultText: String? { resultText }

    var automaticSession: ExternalAutomaticInputSession? {
        guard case .available(let capabilities, let prefix) = gate,
              defaults.string(forKey: automaticKey(prefix)) == "true",
              let input = savedInput(for: capabilities, prefix: prefix) else { return nil }
        let configuration = ExternalDisplayInputConfiguration(
            target: capabilities.target, pcInput: input, automaticEnabled: true
        )
        do { try configuration.validate(capabilities: capabilities) }
        catch { return nil }
        return ExternalAutomaticInputSession(
            configuration: configuration, capabilities: capabilities, controller: inputController
        )
    }

    func selectPCInput(_ input: UInt16) {
        guard case .available(let capabilities, let prefix) = gate,
              input <= UInt16(UInt8.max), capabilities.inputValues.contains(input) else { return }
        persist(String(input), forKey: inputKey(prefix))
    }

    func setAutomaticInput(_ enabled: Bool) {
        if enabled {
            guard case .available(let capabilities, let prefix) = gate,
                  savedInput(for: capabilities, prefix: prefix) != nil else { return }
            persist("true", forKey: automaticKey(prefix))
            return
        }

        guard let prefix = preferencePrefix,
              persistenceFailed || defaults.string(forKey: automaticKey(prefix)) != "false" else { return }
        persist("false", forKey: automaticKey(prefix), clearsPersistenceFailure: true)
    }

    func recordResult(_ result: ExternalDisplayInputResult) {
        resultText = switch result {
        case .confirmed: "显示器已读回所选输入码；PC 画面尚未确认"
        case .unconfirmed: "显示器输入码读回未确认；PC 画面未确认"
        case .unavailable: "自动输入源切换不可用；PC 画面未确认"
        }
        inputSettingsDidChange?()
    }

    private var gate: Gate {
        if persistenceFailed { return .unavailable("无法保存自动输入源设置，已停用自动切换") }
        guard let capabilities else {
            return .unavailable("当前连接尚未验收自动输入源切换")
        }
        do { try capabilities.validate(for: capabilities.target) }
        catch { return .unavailable(reason(for: error as? ExternalDisplayInputFailure)) }
        switch inputController.availability(for: capabilities.target) {
        case .available:
            return .available(capabilities, Self.preferencePrefix(for: capabilities.target))
        case .unavailable(let failure):
            return .unavailable(reason(for: failure))
        }
    }

    private var preferencePrefix: String? {
        guard let target = capabilities?.target else { return nil }
        do { try target.validate() }
        catch { return nil }
        return Self.preferencePrefix(for: target)
    }

    private func savedInput(for capabilities: ExternalDisplayInputCapabilities, prefix: String) -> UInt16? {
        guard let stored = defaults.string(forKey: inputKey(prefix)),
              let input = UInt16(stored), input <= UInt16(UInt8.max),
              capabilities.inputValues.contains(input) else { return nil }
        return input
    }

    private func persist(_ value: String, forKey key: String, clearsPersistenceFailure: Bool = false) {
        defaults.set(value, forKey: key)
        guard synchronizeDefaults() else {
            persistenceFailed = true
            if let prefix = preferencePrefix { defaults.set("false", forKey: automaticKey(prefix)) }
            inputSettingsDidChange?()
            return
        }
        if clearsPersistenceFailure { persistenceFailed = false }
        resultText = nil
        inputSettingsDidChange?()
    }

    private func inputKey(_ prefix: String) -> String { "\(prefix).pcInput" }
    private func automaticKey(_ prefix: String) -> String { "\(prefix).automatic" }

    // Boot session and numeric display IDs bind live operations, not saved physical-monitor preferences.
    private static func preferencePrefix(for target: ExternalDisplayIdentity) -> String {
        let identity = [target.uuid.uuidString, target.edidUUID, target.registryPath]
            .map { "\($0.utf8.count):\($0)" }
            .joined()
        return "externalDisplayInput.v1.\(Data(identity.utf8).base64EncodedString())"
    }

    private func reason(for failure: ExternalDisplayInputFailure?) -> String {
        switch failure {
        case .some(.identityMismatch): "当前连接的显示器身份与验收不匹配"
        case .some(.invalidCapabilities): "当前连接未提供有效的输入源能力"
        case .some(.invalidInput), .some(.unsupportedInput): "所选输入源不受当前显示器支持"
        case .some(.hardwareAcceptanceRequired), .some(.unsupportedTransport), .some(.readbackUnavailable),
             .some(.readbackMismatch), .some(.timedOut), .none:
            "当前连接尚未验收自动输入源切换"
        }
    }
}
