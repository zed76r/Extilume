import Foundation
import ExtilumeCore

// 电源队列不等待控制队列；启动失败后在控制队列外注销通知。
enum InternalSleepPreparation {
    static func startSession(
        on queue: DispatchQueue, cleanupPower: () -> Void, operation: () throws -> Void
    ) rethrows {
        do { try queue.sync(execute: operation) }
        catch { cleanupPower(); throw error }
    }

    static func restore(
        checkAccess: () throws -> Void = {},
        stopObserving: () -> Void, operation: () throws -> RecoveryRecord
    ) rethrows -> RecoveryRecord {
        try checkAccess()
        stopObserving()
        try checkAccess()
        let record = try operation()
        try checkAccess()
        return record
    }
}
