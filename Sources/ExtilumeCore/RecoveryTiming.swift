import Foundation

/// 四个时间戳须来自同一连续单调时基；`faultAt` 由调用方提供最早可能的实际故障时刻，来源未知时不可用通知时刻冒充。
/// 耗时与判定针对给定的 `restoredAt` 核验观测；观测晚到不能证明实际恢复超时。
public struct RecoveryTiming: Equatable {
    public static let deadlineNanoseconds: UInt64 = 10_000_000_000

    public let faultAt: UInt64
    public let latestFaultAt: UInt64
    public let notificationAt: UInt64
    public let restoredAt: UInt64
    public let elapsedNanoseconds: UInt64
    public let suspensionBounds: RecoverySleepBounds?

    public var withinDeadline: Bool { elapsedNanoseconds <= Self.deadlineNanoseconds }
    public var uncertaintyNanoseconds: UInt64 { latestFaultAt - faultAt }
    // 人工确认可能晚于恢复核验，此时不能提供正的耗时下界。
    public var minimumElapsedNanoseconds: UInt64 { restoredAt - min(restoredAt, latestFaultAt) }
    public var awakeElapsedNanoseconds: UInt64 {
        elapsedNanoseconds - min(elapsedNanoseconds, suspensionBounds?.lowerBoundNanoseconds ?? 0)
    }
    public var minimumAwakeElapsedNanoseconds: UInt64 {
        minimumElapsedNanoseconds - min(minimumElapsedNanoseconds, suspensionBounds?.upperBoundNanoseconds ?? 0)
    }
    public var assessment: RecoveryTimingAssessment {
        if withinDeadline { return .withinDeadline }
        if minimumElapsedNanoseconds > Self.deadlineNanoseconds { return .exceeded }
        return .inconclusive
    }
    public var awakeAssessment: RecoveryTimingAssessment {
        if awakeElapsedNanoseconds <= Self.deadlineNanoseconds { return .withinDeadline }
        if minimumAwakeElapsedNanoseconds > Self.deadlineNanoseconds { return .exceeded }
        return .inconclusive
    }

    public init(
        faultAt: UInt64,
        latestFaultAt: UInt64? = nil,
        notificationAt: UInt64,
        restoredAt: UInt64,
        suspensionEvidence: RecoverySuspensionEvidence? = nil,
        clockContext: RecoveryTimingClockContext? = nil
    ) throws {
        let latest = latestFaultAt ?? faultAt
        guard faultAt <= latest, faultAt <= notificationAt, notificationAt <= restoredAt else {
            throw RecoveryTimingError.invalidOrder
        }
        self.faultAt = faultAt
        self.latestFaultAt = latest
        self.notificationAt = notificationAt
        self.restoredAt = restoredAt
        elapsedNanoseconds = restoredAt - faultAt
        if let clockContext {
            guard let boot = clockContext.bootSession,
                  faultAt == clockContext.faultBefore.continuousBeforeNanoseconds,
                  latest == clockContext.faultAfter.continuousAfterNanoseconds,
                  notificationAt == clockContext.notification.continuousAfterNanoseconds,
                  restoredAt == clockContext.restored.continuousAfterNanoseconds else {
                throw RecoveryTimingError.incomparableClock
            }
            suspensionBounds = suspensionEvidence?.sleepBounds(bootSession: boot, latestFaultAt: latest, restoredAt: restoredAt)
        } else {
            // 裸数字无法证明端点与休眠证据同 boot，保持旧的纯算术检查。
            suspensionBounds = nil
        }
    }

    public init(clockContext: RecoveryTimingClockContext, suspensionEvidence: RecoverySuspensionEvidence? = nil) throws {
        try self.init(
            faultAt: clockContext.faultBefore.continuousBeforeNanoseconds,
            latestFaultAt: clockContext.faultAfter.continuousAfterNanoseconds,
            notificationAt: clockContext.notification.continuousAfterNanoseconds,
            restoredAt: clockContext.restored.continuousAfterNanoseconds,
            suspensionEvidence: suspensionEvidence, clockContext: clockContext
        )
    }
}

/// 各端点直接使用采集时的系统时钟样本，不用评估时的 boot 给历史数字补标签。
public struct RecoveryTimingClockContext: Equatable {
    public let faultBefore: RecoveryClockSample
    public let faultAfter: RecoveryClockSample
    public let notification: RecoveryClockSample
    public let restored: RecoveryClockSample

    public init(faultBefore: RecoveryClockSample, faultAfter: RecoveryClockSample, notification: RecoveryClockSample, restored: RecoveryClockSample) {
        self.faultBefore = faultBefore
        self.faultAfter = faultAfter
        self.notification = notification
        self.restored = restored
    }

    var bootSession: UUID? {
        let boot = faultBefore.bootSession
        return [faultAfter, notification, restored].allSatisfy { $0.bootSession == boot } ? boot : nil
    }
}

public enum RecoveryTimingAssessment: Equatable {
    case withinDeadline
    case exceeded
    case inconclusive
}

public enum RecoveryTimingError: Error, Equatable {
    case invalidOrder
    case incomparableClock
}
