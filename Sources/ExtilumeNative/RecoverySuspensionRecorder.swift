import Foundation
import ExtilumeCore

final class RecoverySuspensionRecorderState: @unchecked Sendable {
    private struct PendingSleep {
        let before: RecoveryClockSample
        let willSleepAt: UInt64
        var acknowledged = false
    }

    private let lock = NSLock()
    private let bootSession: UUID
    private let readSample: (UUID) throws -> RecoveryClockSample
    private let readContinuous: () throws -> UInt64
    private var pending: PendingSleep?
    private var intervals: [RecoverySuspensionInterval] = []
    private var invalidated = false

    init(
        bootSession: UUID,
        readSample: @escaping (UUID) throws -> RecoveryClockSample,
        readContinuous: @escaping () throws -> UInt64
    ) {
        self.bootSession = bootSession
        self.readSample = readSample
        self.readContinuous = readContinuous
    }

    func prepareForSleep() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { return true }
        guard pending == nil else {
            invalidateLocked()
            return true
        }
        do {
            let before = try readSample(bootSession)
            let willSleepAt = try readContinuous()
            guard before.bootSession == bootSession else {
                invalidateLocked()
                return true
            }
            pending = PendingSleep(before: before, willSleepAt: willSleepAt)
        } catch {
            invalidateLocked()
        }
        return true
    }

    func didPrepareForSleep(accepted: Bool, acknowledged: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { return }
        guard var pending else {
            invalidateLocked()
            return
        }
        guard accepted, acknowledged else {
            invalidateLocked()
            return
        }
        pending.acknowledged = true
        self.pending = pending
    }

    func didWake() {
        lock.lock()
        defer { lock.unlock() }
        guard !invalidated else { return }
        guard let pending else {
            invalidateLocked()
            return
        }
        self.pending = nil
        guard pending.acknowledged else {
            invalidateLocked()
            return
        }
        do {
            let didWakeAt = try readContinuous()
            let after = try readSample(bootSession)
            guard
                after.bootSession == bootSession,
                pending.before.continuousAfterNanoseconds <= pending.willSleepAt,
                pending.willSleepAt < didWakeAt,
                didWakeAt <= after.continuousBeforeNanoseconds,
                pending.before.continuousAfterNanoseconds <= after.continuousBeforeNanoseconds,
                pending.before.awakeNanoseconds <= after.awakeNanoseconds
            else {
                invalidateLocked()
                return
            }
            intervals.append(RecoverySuspensionInterval(
                before: pending.before,
                after: after,
                powerEvent: RecoveryPowerEventEvidence(
                    bootSession: bootSession,
                    willSleepAtNanoseconds: pending.willSleepAt,
                    didWakeAtNanoseconds: didWakeAt
                )
            ))
        } catch {
            invalidateLocked()
        }
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        invalidateLocked()
    }

    func evidence() -> RecoverySuspensionEvidence {
        lock.lock()
        defer { lock.unlock() }
        return RecoverySuspensionEvidence(intervals: invalidated ? [] : intervals)
    }

    private func invalidateLocked() {
        invalidated = true
        pending = nil
        intervals.removeAll()
    }
}

func recordRecoverySuspensionEvidence(to path: String) throws {
    let session = try currentBootSession()
    let state = RecoverySuspensionRecorderState(
        bootSession: session,
        readSample: { try RecoveryClockSample.capture(bootSession: $0) },
        readContinuous: { try ContinuousClock.nanoseconds() }
    )
    let observer = InternalSystemPowerObserver(
        prepareForSleep: { state.prepareForSleep() },
        didPrepareForSleep: { accepted, acknowledged in
            state.didPrepareForSleep(accepted: accepted, acknowledged: acknowledged)
        },
        didWake: { state.didWake() },
        onFailure: { state.invalidate() }
    )
    try observer.start()
    defer { observer.stop() }
    let sessionNotifications = RecoverySessionNotifications()
    defer { sessionNotifications.stop() }
    print("只读电源与会话通知采集已就绪（stop 或 EOF 结束）。")
    fflush(stdout)
    try waitForRecoveryRecorderStop()
    sessionNotifications.stop()
    observer.stop()
    try writeRecoverySuspensionEvidence(state.evidence(), to: path)
}
