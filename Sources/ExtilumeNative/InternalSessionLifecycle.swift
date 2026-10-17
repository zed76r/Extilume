import ExtilumeCore

enum InternalControlCancellation: Error, Equatable { case pauseRequested }

// 调用者持有授权锁；睡眠请求先撤销写入意图，再由控制队列恢复。
struct InternalSessionLifecycle {
    private(set) var paused = false
    private(set) var sleeping = false
    private(set) var pauseRequested = false
    private(set) var resumeAfterWake = false
    private(set) var faulted = false
    private var pendingSleepPreparations = 0

    var preparingForSleep: Bool { pendingSleepPreparations != 0 }

    var permitsControls: Bool { !sleeping && !pauseRequested && !faulted && !preparingForSleep }
    var shouldResumeAfterWake: Bool { paused && permitsControls && resumeAfterWake }

    mutating func willSleep() {
        resumeAfterWake = resumeAfterWake || !paused
        sleeping = true
        pauseRequested = true
        pendingSleepPreparations += 1
    }

    mutating func didWake() { sleeping = false }

    mutating func finishSleepPreparation(restored: Bool) {
        if !restored || !paused { fail() }
        guard pendingSleepPreparations > 0 else { fail(); return }
        pendingSleepPreparations -= 1
    }

    mutating func requestPause() {
        pauseRequested = true
        resumeAfterWake = false
    }

    mutating func didRestore() {
        paused = true
        pauseRequested = false
    }

    mutating func didConfirmUserConfiguration() {
        guard !faulted else { return }
        paused = true
        resumeAfterWake = true
    }

    mutating func beginReapplication() throws {
        guard paused && permitsControls else { throw RecoveryError.invalidTransition }
        paused = false
        resumeAfterWake = false
    }

    mutating func fail() {
        faulted = true
        resumeAfterWake = false
    }

    mutating func pauseAfterFailure(_ error: Error, protectionReady: Bool) -> Bool {
        if error as? InternalControlCancellation == .pauseRequested,
           protectionReady, pauseRequested, !faulted { return true }
        fail()
        return false
    }
}
