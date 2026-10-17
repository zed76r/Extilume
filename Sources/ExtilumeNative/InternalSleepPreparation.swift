import Foundation
import ExtilumeCore

// 电源确认前有限等待恢复；超时仍保留任务，连续时钟防止跨睡眠误判成功。
final class InternalSleepPreparation: @unchecked Sendable {
    private let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var restored = false

    // 控制队列解开后再排空电源回调，否则回调可能正在等待该队列恢复。
    static func startSession(
        on queue: DispatchQueue, cleanupPower: () -> Void, operation: () throws -> Void
    ) rethrows {
        do { try queue.sync(execute: operation) }
        catch { cleanupPower(); throw error }
    }

    static func complete(
        restored: Bool, acknowledged: Bool, stopping: Bool, stop: () -> Void, resume: () -> Void
    ) {
        if stopping || !restored || !acknowledged { stop() }
        else { resume() }
    }

    static func restore(
        stopObserving: () -> Void, operation: () throws -> RecoveryRecord
    ) rethrows -> RecoveryRecord {
        stopObserving()
        return try operation()
    }

    static func wait(
        on queue: DispatchQueue,
        alreadyOnQueue: Bool,
        deadline: DispatchTime,
        continuousNow: @escaping @Sendable () throws -> UInt64 = { try ContinuousClock.nanoseconds() },
        restore: @escaping @Sendable () -> Bool
    ) -> Bool {
        let preparation = InternalSleepPreparation()
        let started = try? continuousNow()
        let uptime = DispatchTime.now().uptimeNanoseconds
        let budget = deadline.uptimeNanoseconds > uptime ? deadline.uptimeNanoseconds - uptime : 0
        queue.async {
            let restored = restore()
            preparation.lock.withLock { preparation.restored = restored }
            preparation.completed.signal()
        }
        guard !alreadyOnQueue, let started, budget > 0,
              preparation.completed.wait(timeout: deadline) == .success,
              DispatchTime.now().uptimeNanoseconds <= deadline.uptimeNanoseconds,
              let finished = try? continuousNow(), finished >= started,
              finished - started <= budget else { return false }
        return preparation.lock.withLock { preparation.restored }
    }
}
