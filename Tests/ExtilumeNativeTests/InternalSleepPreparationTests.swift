import XCTest
@testable import ExtilumeNative

private final class SleepPreparationState: @unchecked Sendable {
    let lock = NSLock()
    var lifecycle = InternalSessionLifecycle()
    var events: [String] = []
}

final class InternalSleepPreparationTests: XCTestCase {
    func testNotificationReturnWaitsForQueuedApplicationAndVerifiedRestoration() {
        let queue = DispatchQueue(label: "sleep-test.serial")
        let state = SleepPreparationState()
        let releaseApplication = DispatchSemaphore(value: 0)
        let applicationStarted = DispatchSemaphore(value: 0)
        let callbackStarted = DispatchSemaphore(value: 0)
        let callbackReturned = DispatchSemaphore(value: 0)
        queue.async {
            state.lock.withLock { state.events.append("apply") }
            applicationStarted.signal()
            _ = releaseApplication.wait(timeout: .now() + 2)
            state.lock.withLock {
                XCTAssertFalse(state.lifecycle.permitsControls)
                state.events.append("apply-cancelled")
            }
        }
        XCTAssertEqual(applicationStarted.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            state.lock.withLock { state.lifecycle.willSleep() }
            callbackStarted.signal()
            let restored = InternalSleepPreparation.wait(on: queue, alreadyOnQueue: false, deadline: .now() + 2) {
                state.lock.withLock {
                    state.events.append("restore-and-verify")
                    state.lifecycle.didRestore()
                }
                return true
            }
            state.lock.withLock {
                state.lifecycle.finishSleepPreparation(restored: restored)
                state.events.append("notification-return")
            }
            callbackReturned.signal()
        }
        XCTAssertEqual(callbackStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(callbackReturned.wait(timeout: .now() + .milliseconds(20)), .timedOut)
        releaseApplication.signal()
        XCTAssertEqual(callbackReturned.wait(timeout: .now() + 2), .success)
        state.lock.withLock {
            XCTAssertEqual(state.events, ["apply", "apply-cancelled", "restore-and-verify", "notification-return"])
            XCTAssertFalse(state.lifecycle.permitsControls)
            state.lifecycle.didWake()
            XCTAssertTrue(state.lifecycle.shouldResumeAfterWake)
        }
    }

    func testQueuedPreparationTimeoutKeepsRecoveryAndLateCompletionCannotReauthorize() {
        let queue = DispatchQueue(label: "sleep-test.blocked")
        let releaseQueue = DispatchSemaphore(value: 0)
        let state = SleepPreparationState()
        queue.async { _ = releaseQueue.wait(timeout: .now() + 2) }
        state.lifecycle.willSleep()
        let restored = InternalSleepPreparation.wait(
            on: queue, alreadyOnQueue: false, deadline: .now() + .milliseconds(20)
        ) {
            state.lock.withLock {
                state.lifecycle.didRestore()
                state.events.append("late-recovery")
            }
            return true
        }
        XCTAssertFalse(restored)
        state.lock.withLock { state.lifecycle.finishSleepPreparation(restored: restored) }
        releaseQueue.signal()
        queue.sync {}
        state.lock.withLock {
            state.lifecycle.didWake()
            XCTAssertEqual(state.events, ["late-recovery"])
            XCTAssertTrue(state.lifecycle.faulted)
            XCTAssertFalse(state.lifecycle.shouldResumeAfterWake)
        }
    }

    func testOwnerQueueNotificationDoesNotWaitForItselfOrReenterApplication() {
        let queue = DispatchQueue(label: "sleep-test.owner")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let state = SleepPreparationState()
        let started = ProcessInfo.processInfo.systemUptime
        queue.sync {
            state.lifecycle.willSleep()
            state.events.append("apply-start")
            let restored = InternalSleepPreparation.wait(
                on: queue, alreadyOnQueue: DispatchQueue.getSpecific(key: key) != nil,
                deadline: .now() + 1
            ) {
                state.lock.withLock {
                    state.events.append("deferred-recovery")
                    state.lifecycle.didRestore()
                }
                return true
            }
            XCTAssertFalse(restored)
            state.lifecycle.finishSleepPreparation(restored: restored)
            state.events.append("apply-end")
        }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 0.5)
        queue.sync {}
        state.lock.withLock {
            XCTAssertEqual(state.events, ["apply-start", "apply-end", "deferred-recovery"])
            state.lifecycle.didWake()
            XCTAssertTrue(state.lifecycle.faulted)
            XCTAssertFalse(state.lifecycle.shouldResumeAfterWake)
        }
    }

    func testUnverifiedRecoveryCannotBecomeSuccessfulPreparation() {
        let queue = DispatchQueue(label: "sleep-test.failure")
        var state = InternalSessionLifecycle()
        state.willSleep()
        let restored = InternalSleepPreparation.wait(on: queue, alreadyOnQueue: false, deadline: .now() + 1) { false }
        state.finishSleepPreparation(restored: restored)
        state.didRestore()
        state.didWake()
        XCTAssertTrue(state.faulted)
        XCTAssertFalse(state.shouldResumeAfterWake)
    }

    func testExpiredNotificationBudgetCannotReportSuccess() {
        let queue = DispatchQueue(label: "sleep-test.expired")
        XCTAssertFalse(InternalSleepPreparation.wait(
            on: queue, alreadyOnQueue: false, deadline: .now() - .milliseconds(1)
        ) { true })
        queue.sync {}
    }

    func testTimeoutDuringWitnessKeepsRunningRecoveryButLatchesFault() {
        let queue = DispatchQueue(label: "sleep-test.witness")
        let state = SleepPreparationState()
        let witnessStarted = DispatchSemaphore(value: 0)
        let releaseWitness = DispatchSemaphore(value: 0)
        state.lifecycle.willSleep()
        let restored = InternalSleepPreparation.wait(
            on: queue, alreadyOnQueue: false, deadline: .now() + .milliseconds(50)
        ) {
            witnessStarted.signal()
            _ = releaseWitness.wait(timeout: .now() + 2)
            state.lock.withLock { state.lifecycle.didRestore() }
            return true
        }
        XCTAssertEqual(witnessStarted.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(restored)
        state.lock.withLock {
            state.lifecycle.finishSleepPreparation(restored: restored)
            state.lifecycle.didWake()
            XCTAssertTrue(state.lifecycle.faulted)
        }
        releaseWitness.signal()
        queue.sync {}
        state.lock.withLock {
            XCTAssertTrue(state.lifecycle.paused)
            XCTAssertTrue(state.lifecycle.faulted)
            XCTAssertFalse(state.lifecycle.shouldResumeAfterWake)
        }
    }

    func testEarlyWakeAndProtectionLossCannotCrossPreparationBoundary() {
        for protectionLost in [false, true] {
            var state = InternalSessionLifecycle()
            state.willSleep()
            state.didWake()
            state.didRestore()
            if protectionLost { state.fail() }
            XCTAssertFalse(state.permitsControls)
            XCTAssertFalse(state.shouldResumeAfterWake)
            state.finishSleepPreparation(restored: true)
            XCTAssertEqual(state.shouldResumeAfterWake, !protectionLost)
        }
    }

    func testOverlappingSleepPreparationsRemainGatedUntilBothComplete() {
        var state = InternalSessionLifecycle()
        state.willSleep()
        state.willSleep()
        state.didRestore()
        state.didWake()
        state.finishSleepPreparation(restored: true)
        XCTAssertFalse(state.permitsControls)
        state.finishSleepPreparation(restored: true)
        XCTAssertTrue(state.shouldResumeAfterWake)
    }

    func testLaterSleepPauseDoesNotInvalidateEarlierVerifiedRestoration() {
        var state = InternalSessionLifecycle()
        state.willSleep()
        state.didRestore()
        state.willSleep()
        state.finishSleepPreparation(restored: true)
        XCTAssertFalse(state.faulted)
        XCTAssertFalse(state.permitsControls)
        state.didWake()
        XCTAssertFalse(state.shouldResumeAfterWake)
        state.didRestore()
        state.finishSleepPreparation(restored: true)
        XCTAssertTrue(state.shouldResumeAfterWake)
    }

    func testPausedSessionStillRequiresSuccessfulSleepReverification() {
        let queue = DispatchQueue(label: "sleep-test.paused")
        var state = InternalSessionLifecycle()
        state.didConfirmUserConfiguration()
        state.willSleep()
        let restored = InternalSleepPreparation.wait(on: queue, alreadyOnQueue: false, deadline: .now() + 1) { false }
        state.finishSleepPreparation(restored: restored)
        state.didWake()
        XCTAssertTrue(state.paused)
        XCTAssertTrue(state.faulted)
        XCTAssertFalse(state.shouldResumeAfterWake)
    }
}
