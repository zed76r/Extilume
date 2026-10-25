import Darwin
import Foundation

/// 两种系统时钟的配对采样；boot UUID 仅供私有恢复证据校验。
public struct RecoveryClockSample: Codable, Equatable {
    public let bootSession: UUID
    public let continuousBeforeNanoseconds: UInt64
    public let awakeNanoseconds: UInt64
    public let continuousAfterNanoseconds: UInt64

    public var samplingUncertaintyNanoseconds: UInt64 {
        continuousAfterNanoseconds - continuousBeforeNanoseconds
    }

    public init(
        bootSession: UUID,
        continuousBeforeNanoseconds: UInt64,
        awakeNanoseconds: UInt64,
        continuousAfterNanoseconds: UInt64
    ) throws {
        guard bootSession.uuidString != "00000000-0000-0000-0000-000000000000" else {
            throw RecoveryClockSampleError.invalidBootSession
        }
        guard continuousBeforeNanoseconds <= continuousAfterNanoseconds else {
            throw RecoveryClockSampleError.invalidOrder
        }
        self.bootSession = bootSession
        self.continuousBeforeNanoseconds = continuousBeforeNanoseconds
        self.awakeNanoseconds = awakeNanoseconds
        self.continuousAfterNanoseconds = continuousAfterNanoseconds
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            bootSession: values.decode(UUID.self, forKey: .bootSession),
            continuousBeforeNanoseconds: values.decode(UInt64.self, forKey: .continuousBeforeNanoseconds),
            awakeNanoseconds: values.decode(UInt64.self, forKey: .awakeNanoseconds),
            continuousAfterNanoseconds: values.decode(UInt64.self, forKey: .continuousAfterNanoseconds)
        )
    }

    public static func capture(
        bootSession: UUID
    ) throws -> RecoveryClockSample {
        try capture(
            bootSession: bootSession,
            readContinuous: { try ContinuousClock.nanoseconds() },
            readAwake: { try awakeNanoseconds() }
        )
    }

    public static func capture(
        bootSession: UUID,
        readContinuous: () throws -> UInt64,
        readAwake: () throws -> UInt64
    ) throws -> RecoveryClockSample {
        let before = try readContinuous()
        let awake = try readAwake()
        let after = try readContinuous()
        return try RecoveryClockSample(
            bootSession: bootSession,
            continuousBeforeNanoseconds: before,
            awakeNanoseconds: awake,
            continuousAfterNanoseconds: after
        )
    }

    public static func provenSleepBounds(
        from start: RecoveryClockSample,
        to end: RecoveryClockSample,
        faultAt: UInt64,
        latestFaultAt: UInt64,
        restoredAt: UInt64,
        powerEvent: RecoveryPowerEventEvidence
    ) -> RecoverySleepBounds? {
        guard
            start.bootSession == end.bootSession,
            start.bootSession == powerEvent.bootSession,
            start.continuousBeforeNanoseconds <= start.continuousAfterNanoseconds,
            end.continuousBeforeNanoseconds <= end.continuousAfterNanoseconds,
            faultAt <= latestFaultAt,
            latestFaultAt <= start.continuousBeforeNanoseconds,
            start.continuousAfterNanoseconds <= end.continuousBeforeNanoseconds,
            end.continuousAfterNanoseconds <= restoredAt,
            start.awakeNanoseconds <= end.awakeNanoseconds,
            latestFaultAt <= powerEvent.willSleepAtNanoseconds,
            powerEvent.willSleepAtNanoseconds < powerEvent.didWakeAtNanoseconds,
            powerEvent.didWakeAtNanoseconds <= restoredAt,
            start.continuousAfterNanoseconds <= powerEvent.willSleepAtNanoseconds,
            powerEvent.didWakeAtNanoseconds <= end.continuousBeforeNanoseconds
        else { return nil }

        let awakeDelta = end.awakeNanoseconds - start.awakeNanoseconds
        let continuousLower = end.continuousBeforeNanoseconds - start.continuousAfterNanoseconds
        let continuousUpper = end.continuousAfterNanoseconds - start.continuousBeforeNanoseconds
        guard continuousUpper >= awakeDelta else { return nil }

        let rawLower = continuousLower > awakeDelta ? continuousLower - awakeDelta : 0
        let rawUpper = continuousUpper - awakeDelta
        // 两种时钟分别向下取整，差值两端各留 1 ns 余量。
        let lower = rawLower > 2 ? rawLower - 2 : 0
        let (expandedUpper, upperOverflow) = rawUpper.addingReportingOverflow(2)
        let upper = upperOverflow ? UInt64.max : expandedUpper
        guard lower <= upper else { return nil }
        return RecoverySleepBounds(lowerBoundNanoseconds: lower, upperBoundNanoseconds: upper)
    }

    private static func awakeNanoseconds() throws -> UInt64 {
        var timebase = mach_timebase_info_data_t()
        guard mach_timebase_info(&timebase) == KERN_SUCCESS else { throw ClockError.invalidTimebase }
        return try ContinuousClock.convert(
            ticks: mach_absolute_time(), numerator: timebase.numer, denominator: timebase.denom
        )
    }

    private enum CodingKeys: String, CodingKey {
        case bootSession
        case continuousBeforeNanoseconds
        case awakeNanoseconds
        case continuousAfterNanoseconds
    }
}

public struct RecoveryPowerEventEvidence: Codable, Equatable {
    public let bootSession: UUID
    public let willSleepAtNanoseconds: UInt64
    public let didWakeAtNanoseconds: UInt64

    public init(bootSession: UUID, willSleepAtNanoseconds: UInt64, didWakeAtNanoseconds: UInt64) {
        self.bootSession = bootSession
        self.willSleepAtNanoseconds = willSleepAtNanoseconds
        self.didWakeAtNanoseconds = didWakeAtNanoseconds
    }
}

public struct RecoverySuspensionInterval: Codable, Equatable {
    public let before: RecoveryClockSample
    public let after: RecoveryClockSample
    public let powerEvent: RecoveryPowerEventEvidence

    public init(before: RecoveryClockSample, after: RecoveryClockSample, powerEvent: RecoveryPowerEventEvidence) {
        self.before = before
        self.after = after
        self.powerEvent = powerEvent
    }
}

public struct RecoverySuspensionEvidence: Codable, Equatable {
    public let intervals: [RecoverySuspensionInterval]

    public init(intervals: [RecoverySuspensionInterval]) {
        self.intervals = intervals
    }

    public func sleepBounds(bootSession: UUID, latestFaultAt: UInt64, restoredAt: UInt64) -> RecoverySleepBounds? {
        guard !intervals.isEmpty else { return nil }
        var lowerTotal: UInt64 = 0
        var upperTotal: UInt64 = 0
        var previous: RecoverySuspensionInterval?
        for interval in intervals {
            guard
                interval.before.bootSession == bootSession,
                interval.after.bootSession == bootSession,
                interval.powerEvent.bootSession == bootSession
            else { return nil }
            guard let bounds = RecoveryClockSample.provenSleepBounds(
                from: interval.before,
                to: interval.after,
                faultAt: latestFaultAt,
                latestFaultAt: latestFaultAt,
                restoredAt: restoredAt,
                powerEvent: interval.powerEvent
            ) else { return nil }

            if let previous {
                guard
                    previous.after.continuousAfterNanoseconds <= interval.before.continuousBeforeNanoseconds,
                    previous.after.awakeNanoseconds <= interval.before.awakeNanoseconds,
                    previous.powerEvent.didWakeAtNanoseconds < interval.powerEvent.willSleepAtNanoseconds
                else { return nil }
            }
            let (newLowerTotal, lowerOverflow) = lowerTotal.addingReportingOverflow(bounds.lowerBoundNanoseconds)
            let (newUpperTotal, upperOverflow) = upperTotal.addingReportingOverflow(bounds.upperBoundNanoseconds)
            guard !lowerOverflow, !upperOverflow else { return nil }
            lowerTotal = newLowerTotal
            upperTotal = newUpperTotal
            previous = interval
        }

        return RecoverySleepBounds(lowerBoundNanoseconds: lowerTotal, upperBoundNanoseconds: upperTotal)
    }
}

public struct RecoverySleepBounds: Equatable {
    public let lowerBoundNanoseconds: UInt64
    public let upperBoundNanoseconds: UInt64

    fileprivate init(lowerBoundNanoseconds: UInt64, upperBoundNanoseconds: UInt64) {
        self.lowerBoundNanoseconds = lowerBoundNanoseconds
        self.upperBoundNanoseconds = upperBoundNanoseconds
    }
}

public enum RecoveryClockSampleError: Error, Equatable {
    case invalidOrder
    case invalidBootSession
}
