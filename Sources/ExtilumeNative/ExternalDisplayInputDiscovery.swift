import ExtilumeCore
import Foundation

@MainActor
protocol ExternalDisplayInputSourcesSelecting: AnyObject {
    var detectedInputOptions: [UInt16] { get }
    var detectingInputSources: Bool { get }
    var inputDiscoveryMessage: String? { get }
    var canDetectInputSources: Bool { get }
    var canSelectDetectedInput: Bool { get }
    func detectInputSources()
    func disableExternal(selectingInput input: UInt16)
}

// 能力查询不执行 Set VCP；DDC 查询自身仍包含 I2C 请求包。
func discoverExternalDisplayInputCapabilities(checkAccess: @escaping @Sendable () throws -> Void) throws -> ExternalDisplayInputCapabilities {
    try checkAccess()
    let before = try freshSnapshot()
    guard before.assessment.isSupported, before.displays.count == 2,
          let target = before.displays.first(where: { $0.identity == .physical }),
          let captured = try readExternalDisplayState(target.id), captured.isEnabled,
          captured.identity.uuid == target.identityUUID else { throw ExternalDisplayInputFailure.identityMismatch }
    let initial = try freshExternalDisplay(identity: captured.identity, numericIDHint: captured.id)
    guard initial == captured else { throw ExternalDisplayInputFailure.identityMismatch }
    try checkAccess()
    let deadline = try ContinuousClock.nanoseconds() + 3_000_000_000
    let reply = try runExternalDisplayInputProbe(ExternalDisplayInputProbeRequest(target: captured.identity,
        operation: .capabilities, deadlineNanoseconds: deadline), checkAccess: checkAccess)
    guard case .capabilities(let capabilities) = reply else {
        if case .failed(let failure) = reply { throw failure }
        throw ExternalDisplayInputFailure.invalidCapabilities
    }
    try checkAccess()
    guard try freshExternalDisplay(identity: captured.identity, numericIDHint: captured.id) == initial,
          try freshSnapshot() == before else { throw ExternalDisplayInputFailure.identityMismatch }
    try capabilities.validate(for: captured.identity)
    try checkAccess()
    return capabilities
}

final class ExternalInputDiscoveryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw RecoveryError.invalidTransition }
    }
}
