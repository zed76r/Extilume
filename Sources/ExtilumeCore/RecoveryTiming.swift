/// 三个时间戳须来自同一连续单调时基；`faultAt` 由调用方提供最早可能的实际故障时刻，来源未知时不可用通知时刻冒充。
public struct RecoveryTiming: Equatable {
    public static let deadlineNanoseconds: UInt64 = 10_000_000_000

    public let faultAt: UInt64
    public let notificationAt: UInt64
    public let restoredAt: UInt64
    public let elapsedNanoseconds: UInt64

    public var withinDeadline: Bool { elapsedNanoseconds <= Self.deadlineNanoseconds }

    public init(faultAt: UInt64, notificationAt: UInt64, restoredAt: UInt64) throws {
        guard faultAt <= notificationAt, notificationAt <= restoredAt else {
            throw RecoveryTimingError.invalidOrder
        }
        self.faultAt = faultAt
        self.notificationAt = notificationAt
        self.restoredAt = restoredAt
        elapsedNanoseconds = restoredAt - faultAt
    }
}

public enum RecoveryTimingError: Error, Equatable {
    case invalidOrder
}
