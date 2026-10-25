import Foundation
import ExtilumeCore

final class InternalRecoveryClock: @unchecked Sendable {
    private struct PendingSleep {
        let before: RecoveryClockSample
        let willSleepAt: UInt64
    }

    private let lock = NSLock()
    private let now: @Sendable () throws -> UInt64
    private let sample: @Sendable (UUID) throws -> RecoveryClockSample
    private var bootSession: UUID?
    private var startAttempted = false
    private var epochInvalidated = false
    private var faultStartedAt: UInt64?
    private var pendingSleep: PendingSleep?
    private var intervals: [RecoverySuspensionInterval] = []

    init(
        now: @escaping @Sendable () throws -> UInt64 = { try ContinuousClock.nanoseconds() },
        sample: @escaping @Sendable (UUID) throws -> RecoveryClockSample = {
            try RecoveryClockSample.capture(bootSession: $0)
        }
    ) {
        self.now = now
        self.sample = sample
    }

    func setBootSession(_ bootSession: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let previous = self.bootSession, previous != bootSession {
            epochInvalidated = true
            intervals.removeAll()
            pendingSleep = nil
        }
        self.bootSession = bootSession
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !startAttempted else { return }
        startAttempted = true
        faultStartedAt = try? now()
    }

    // 暂态判定失败时可补入更早的原点；无效时钟不能被后来的成功读取修补。
    func start(at timestamp: UInt64?) {
        lock.lock()
        defer { lock.unlock() }
        if !startAttempted {
            startAttempted = true
            faultStartedAt = timestamp
        } else if let previous = faultStartedAt, let timestamp {
            faultStartedAt = min(previous, timestamp)
        } else {
            faultStartedAt = nil
        }
    }

    func willSleep() {
        lock.lock()
        defer { lock.unlock() }
        guard pendingSleep == nil, let bootSession,
              let before = try? sample(bootSession),
              let willSleepAt = try? now() else { return }
        pendingSleep = PendingSleep(before: before, willSleepAt: willSleepAt)
    }

    func didWake() {
        lock.lock()
        defer { lock.unlock() }
        guard let pendingSleep else { return }
        self.pendingSleep = nil
        guard faultStartedAt != nil, let bootSession,
              let didWakeAt = try? now(),
              let after = try? sample(bootSession) else { return }
        intervals.append(RecoverySuspensionInterval(
            before: pendingSleep.before,
            after: after,
            powerEvent: RecoveryPowerEventEvidence(
                bootSession: bootSession,
                willSleepAtNanoseconds: pendingSleep.willSleepAt,
                didWakeAtNanoseconds: didWakeAt
            )
        ))
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        startAttempted = false
        epochInvalidated = false
        faultStartedAt = nil
        pendingSleep = nil
        intervals.removeAll()
    }

    func elapsedNanoseconds() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !epochInvalidated, let faultStartedAt, let current = try? now(), current >= faultStartedAt else { return nil }
        let elapsed = current - faultStartedAt
        guard !intervals.isEmpty, let bootSession, let bounds = RecoverySuspensionEvidence(intervals: intervals)
            .sleepBounds(bootSession: bootSession, latestFaultAt: faultStartedAt, restoredAt: current) else { return elapsed }
        return elapsed - min(elapsed, bounds.lowerBoundNanoseconds)
    }
}
