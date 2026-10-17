import Foundation

// 通知返回会放行系统休眠；有限等待恢复，超时仍保留其任务与责任。
final class InternalSleepPreparation: @unchecked Sendable {
    private let completed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var restored = false

    static func wait(
        on queue: DispatchQueue,
        alreadyOnQueue: Bool,
        deadline: DispatchTime,
        restore: @escaping @Sendable () -> Bool
    ) -> Bool {
        let preparation = InternalSleepPreparation()
        queue.async {
            let restored = restore()
            preparation.lock.withLock { preparation.restored = restored }
            preparation.completed.signal()
        }
        guard !alreadyOnQueue,
              preparation.completed.wait(timeout: deadline) == .success,
              DispatchTime.now().uptimeNanoseconds <= deadline.uptimeNanoseconds else { return false }
        return preparation.lock.withLock { preparation.restored }
    }
}
