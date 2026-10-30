import ExtilumeCore
import Foundation

// 用户的连接确认只适用于这一份责任记录、这一次恢复尝试，不写入偏好或磁盘。
final class ExternalConnectionRecoveryConfirmation: @unchecked Sendable {
    let id = UUID()
    private let record: RecoveryRecord
    private let lock = NSLock()
    private var consumed = false

    init(record: RecoveryRecord) { self.record = record }

    func consume(for current: RecoveryRecord) -> Bool {
        lock.withLock {
            guard !consumed else { return false }
            consumed = true
            return current == record
        }
    }

    func cancel() { lock.withLock { consumed = true } }
}

enum ExternalConnectionRecoveryError: Error, Equatable {
    case confirmationRequired
}

@MainActor
protocol ExternalConnectionRecoveryControlling: AnyObject, Sendable {
    var hasExternalRecoveryOwner: Bool { get }
    func prepareConnectionRecovery(completion: @escaping @Sendable (Result<ExternalConnectionRecoveryConfirmation?, Error>) -> Void)
    func recoverAfterConfirmingConnection(_ confirmation: ExternalConnectionRecoveryConfirmation)
}

extension ExternalConnectionRecoveryControlling {
    var hasExternalRecoveryOwner: Bool { true }
}
