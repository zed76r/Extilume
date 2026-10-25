import ExtilumeCore
import Foundation

enum InternalControlCancellation: Error, Equatable { case pauseRequested }

// 调用者持有授权锁；电源确认不等待恢复，唤醒后先恢复再重新接管。
struct InternalSessionLifecycle {
    private(set) var paused = false
    private(set) var sleeping = false
    private(set) var pauseRequested = false
    private(set) var resumeAfterWake = false
    private(set) var faulted = false
    private(set) var exiting = false
    private(set) var stopRequested = false
    private(set) var wakeRecoveryRequired = false
    private(set) var sleepEpoch = UUID()
    private var pendingSleepPreparations = 0

    var preparingForSleep: Bool { pendingSleepPreparations != 0 }

    var permitsRecovery: Bool { !sleeping && !preparingForSleep && !exiting }
    var permitsControls: Bool { permitsRecovery && !pauseRequested && !faulted && !stopRequested && !wakeRecoveryRequired }
    var shouldRecoverAfterWake: Bool { wakeRecoveryRequired && permitsRecovery }
    var shouldResumeAfterWake: Bool { paused && permitsControls && resumeAfterWake }

    @discardableResult
    mutating func willSleep() -> Bool {
        guard !exiting else { return false }
        if !sleeping {
            resumeAfterWake = resumeAfterWake || (!paused && !pauseRequested && !faulted && !stopRequested)
            sleepEpoch = UUID()
        }
        sleeping = true
        pauseRequested = true
        wakeRecoveryRequired = true
        pendingSleepPreparations += 1
        return true
    }

    mutating func didWake() { sleeping = false }

    // 确认只结算通知，不表示内屏或桌面已经恢复。
    mutating func finishSleepPreparation(acknowledged: Bool) {
        if !acknowledged { fail() }
        guard pendingSleepPreparations > 0 else { fail(); return }
        pendingSleepPreparations -= 1
    }

    mutating func beginExitAfterRecovery(verifiedSleepEpoch: UUID, powerAllowsExit: () -> Bool) -> Bool {
        guard permitsRecovery, sleepEpoch == verifiedSleepEpoch, powerAllowsExit() else { return false }
        exiting = true
        resumeAfterWake = false
        return true
    }

    mutating func requestPause() {
        pauseRequested = true
        resumeAfterWake = false
    }

    mutating func requestStop() {
        stopRequested = true
        requestPause()
    }

    mutating func didRestore() {
        guard permitsRecovery else { return }
        paused = true
        pauseRequested = false
        wakeRecoveryRequired = false
    }

    mutating func didConfirmUserConfiguration() {
        guard !faulted else { return }
        paused = true
        resumeAfterWake = true
    }

    mutating func beginReapplication(isCurrent: Bool = true) throws {
        guard !faulted, !exiting else { throw RecoveryError.invalidTransition }
        if !isCurrent || sleeping || pauseRequested || preparingForSleep || stopRequested || wakeRecoveryRequired {
            throw InternalControlCancellation.pauseRequested
        }
        guard paused else { throw RecoveryError.invalidTransition }
        paused = false
        resumeAfterWake = false
    }

    mutating func fail() {
        faulted = true
        resumeAfterWake = false
    }

    mutating func pauseAfterFailure(_ error: Error, protectionReady: Bool) -> Bool {
        if (error as? InternalControlCancellation == .pauseRequested || error as? InternalPowerGateError == .suspended),
           protectionReady, (pauseRequested || sleeping || stopRequested || wakeRecoveryRequired), !faulted { return true }
        fail()
        return false
    }
}
