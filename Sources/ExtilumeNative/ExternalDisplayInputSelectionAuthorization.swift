import Foundation
import ExtilumeCore

final class ExternalDisplayInputSelectionAuthorization: @unchecked Sendable {
    let configuration: ExternalDisplayInputConfiguration
    let deadlineNanoseconds: UInt64
    private let lock = NSLock()
    private var consumed = false

    init(configuration: ExternalDisplayInputConfiguration, deadlineNanoseconds: UInt64) {
        self.configuration = configuration
        self.deadlineNanoseconds = deadlineNanoseconds
    }

    func isAvailable(for target: ExternalDisplayIdentity, now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !consumed && configuration.target == target && now < deadlineNanoseconds
    }

    func consume(configuration: ExternalDisplayInputConfiguration, deadlineNanoseconds: UInt64, now: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !consumed else { return false }
        consumed = true
        return self.configuration == configuration && self.deadlineNanoseconds == deadlineNanoseconds && now < deadlineNanoseconds
    }
}
