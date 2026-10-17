/// 四个时间戳须来自同一连续单调时基；`faultAt` 由调用方提供最早可能的实际故障时刻，来源未知时不可用通知时刻冒充。
/// 耗时与判定针对给定的 `restoredAt` 核验观测；观测晚到不能证明实际恢复超时。
public struct RecoveryTiming: Equatable {
    public static let deadlineNanoseconds: UInt64 = 10_000_000_000

    public let faultAt: UInt64
    public let latestFaultAt: UInt64
    public let notificationAt: UInt64
    public let restoredAt: UInt64
    public let elapsedNanoseconds: UInt64

    public var withinDeadline: Bool { elapsedNanoseconds <= Self.deadlineNanoseconds }
    public var uncertaintyNanoseconds: UInt64 { latestFaultAt - faultAt }
    // 人工确认可能晚于恢复核验，此时不能提供正的耗时下界。
    public var minimumElapsedNanoseconds: UInt64 { restoredAt - min(restoredAt, latestFaultAt) }
    public var assessment: RecoveryTimingAssessment {
        if withinDeadline { return .withinDeadline }
        if minimumElapsedNanoseconds > Self.deadlineNanoseconds { return .exceeded }
        return .inconclusive
    }

    public init(faultAt: UInt64, latestFaultAt: UInt64? = nil, notificationAt: UInt64, restoredAt: UInt64) throws {
        let latest = latestFaultAt ?? faultAt
        guard faultAt <= latest, faultAt <= notificationAt, notificationAt <= restoredAt else {
            throw RecoveryTimingError.invalidOrder
        }
        self.faultAt = faultAt
        self.latestFaultAt = latest
        self.notificationAt = notificationAt
        self.restoredAt = restoredAt
        elapsedNanoseconds = restoredAt - faultAt
    }
}

public enum RecoveryTimingAssessment: Equatable {
    case withinDeadline
    case exceeded
    case inconclusive
}

public enum RecoveryTimingError: Error, Equatable {
    case invalidOrder
}
