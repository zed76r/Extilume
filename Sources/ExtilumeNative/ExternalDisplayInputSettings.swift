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
    let permitsExplicitInputSelection: Bool
    private let discoverInputs: @Sendable (@escaping @Sendable () throws -> Void) throws -> ExternalDisplayInputCapabilities
    private let explicitController: (ExternalDisplayInputSelectionAuthorization) -> any ExternalDisplayInputControlling
    private let now: () throws -> UInt64
    private var detectedCapabilities: ExternalDisplayInputCapabilities?
    private var detectedUntil: UInt64 = 0
    private var detectionGeneration = UUID()
    private var discoveryCancellation: ExternalInputDiscoveryCancellation?
    private(set) var detectingInputSources = false
    private(set) var inputDiscoveryMessage: String? = "未检测输入源；可直接停用外接屏"

    var inputSettingsDidChange: (@MainActor () -> Void)?

    init(defaults: UserDefaults = .standard,
         capabilities: ExternalDisplayInputCapabilities? = nil,
         inputController: any ExternalDisplayInputControlling = ExternalDisplayInputController(),
         synchronize: (() -> Bool)? = nil,
         permitsExplicitInputSelection: Bool = false,
         discoverInputs: @escaping @Sendable (@escaping @Sendable () throws -> Void) throws -> ExternalDisplayInputCapabilities = discoverExternalDisplayInputCapabilities,
         explicitController: @escaping (ExternalDisplayInputSelectionAuthorization) -> any ExternalDisplayInputControlling = {
             ExternalDisplayInputController(explicitSelectionAuthorization: $0)
         },
         now: @escaping () throws -> UInt64 = { try ContinuousClock.nanoseconds() }) {
        self.defaults = defaults
        self.capabilities = capabilities
        self.inputController = inputController
        synchronizeDefaults = synchronize ?? { defaults.synchronize() }
        self.permitsExplicitInputSelection = permitsExplicitInputSelection
        self.discoverInputs = discoverInputs
        self.explicitController = explicitController
        self.now = now
    }

    var detectedInputOptions: [UInt16] {
        guard permitsExplicitInputSelection, !detectingInputSources,
              let detectedCapabilities, let time = try? now(), time < detectedUntil,
              (try? detectedCapabilities.validate(for: detectedCapabilities.target)) != nil else { return [] }
        return detectedCapabilities.inputValues.sorted()
    }

    func detectInputSources() {
        guard permitsExplicitInputSelection, !detectingInputSources else { return }
        detectingInputSources = true
        detectedCapabilities = nil
        inputDiscoveryMessage = "正在检测显示器输入源；可直接停用外接屏"
        let generation = UUID()
        detectionGeneration = generation
        let discover = discoverInputs
        let cancellation = ExternalInputDiscoveryCancellation()
        discoveryCancellation = cancellation
        inputSettingsDidChange?()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try discover { try cancellation.check() } }
            Task { @MainActor [weak self] in
                guard let self, self.detectionGeneration == generation else { return }
                self.detectingInputSources = false
                self.discoveryCancellation = nil
                do {
                    let capabilities = try result.get()
                    try capabilities.validate(for: capabilities.target)
                    self.detectedCapabilities = capabilities
                    self.detectedUntil = try self.now() + 30_000_000_000
                    self.inputDiscoveryMessage = "已读取支持的输入码；请按显示器实际端口选择"
                } catch {
                    self.detectedCapabilities = nil
                    self.inputDiscoveryMessage = "未能识别输入源，请手动选源；可直接停用外接屏"
                }
                self.inputSettingsDidChange?()
            }
        }
    }

    func cancelInputDetection() {
        guard detectingInputSources else { return }
        detectionGeneration = UUID()
        discoveryCancellation?.cancel()
        discoveryCancellation = nil
        detectingInputSources = false
        inputDiscoveryMessage = "检测已取消；可直接停用外接屏"
        inputSettingsDidChange?()
    }

    func explicitSession(selecting input: UInt16) -> ExternalAutomaticInputSession? {
        guard detectedInputOptions.contains(input), let capabilities = detectedCapabilities,
              let time = try? now() else {
            inputDiscoveryMessage = "输入源列表不可用或已过期，请重新检测；可直接停用外接屏"
            inputSettingsDidChange?()
            return nil
        }
        let configuration = ExternalDisplayInputConfiguration(target: capabilities.target, pcInput: input, automaticEnabled: true)
        let deadline = time + 3_000_000_000
        let authorization = ExternalDisplayInputSelectionAuthorization(configuration: configuration, deadlineNanoseconds: deadline)
        return ExternalAutomaticInputSession(configuration: configuration, capabilities: capabilities,
            controller: explicitController(authorization), deadlineNanoseconds: deadline)
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
        case .confirmed: "显示器已读回所选输入码；实际画面请确认"
        case .unconfirmed: "输入源切换未确认，请手动选源；外接屏保持停用"
        case .unavailable: "输入源切换不可用，请手动选源；外接屏保持停用"
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
