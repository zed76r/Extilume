import ExtilumeCore
import Foundation

enum ExternalDisplayInputResult: Sendable { case confirmed, unconfirmed, unavailable }

// 仅由显示控制队列使用；每次显式进入准备一次，不用于连接、唤醒或启动恢复。
struct ExternalAutomaticInputSession: @unchecked Sendable {
    let configuration: ExternalDisplayInputConfiguration
    let capabilities: ExternalDisplayInputCapabilities
    let controller: any ExternalDisplayInputControlling
    private var prepared = false
    private var attempted = false
    private var deadline: UInt64 = 0

    init(configuration: ExternalDisplayInputConfiguration, capabilities: ExternalDisplayInputCapabilities,
         controller: any ExternalDisplayInputControlling) {
        self.configuration = configuration
        self.capabilities = capabilities
        self.controller = controller
    }

    mutating func prepare(for target: ExternalDisplayIdentity) -> Bool {
        prepared = false
        attempted = false
        guard configuration.automaticEnabled, configuration.target == target,
              controller.availability(for: target) == .available else { return false }
        do {
            try configuration.validate(capabilities: capabilities)
            deadline = try ContinuousClock.nanoseconds() + 3_000_000_000
            let current = try controller.readCapabilities(for: target, deadlineNanoseconds: deadline)
            try configuration.validate(capabilities: current)
            prepared = true
        } catch { return false }
        return prepared
    }

    mutating func sendOnce(to target: ExternalDisplayIdentity) -> ExternalDisplayInputResult {
        guard prepared, !attempted, target == configuration.target else { return .unavailable }
        attempted = true
        do {
            try controller.sendOnce(configuration, capabilities: capabilities, deadlineNanoseconds: deadline)
            return .confirmed
        } catch { return .unconfirmed }
    }
}
