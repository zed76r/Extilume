import XCTest
import ExtilumeCore
@testable import ExtilumeNative

private final class SleepPreparationState: @unchecked Sendable {
    let lock = NSLock()
    var lifecycle = InternalSessionLifecycle()
    var events: [String] = []
    var clockValues: [UInt64] = []
}

final class InternalSleepPreparationTests: XCTestCase {
    func testRestoreRetiresObserverBeforeExpectedNegativeAndAllowsVerifiedWake() throws {
        let identity = UUID()
        let layout = try DisplayLayout(main: identity, origins: [identity: DisplayOrigin(x: 0, y: 0)])
        let record = try RecoveryRecord(baseline: layout, target: layout)
        var lifecycle = InternalSessionLifecycle()
        lifecycle.didConfirmUserConfiguration()
        try lifecycle.beginReapplication()
        lifecycle.willSleep()
        XCTAssertFalse(lifecycle.permitsControls)
        var candidates = ConnectionCandidateState()
        XCTAssertTrue(candidates.matched(entryID: 42, service: .videoInterface, location: "External"))
        var observing = true
        var emittedNegative = false

        let restored = InternalSleepPreparation.restore(stopObserving: { observing = false }) {
            emittedNegative = true
            if observing {
                _ = candidates.invalidate(entryID: 0, terminated: false)
                lifecycle.fail()
            }
            lifecycle.didRestore()
            return record
        }

        XCTAssertEqual(restored, record)
        XCTAssertTrue(emittedNegative)
        XCTAssertFalse(observing)
        XCTAssertTrue(candidates.hasCandidates)
        XCTAssertFalse(candidates.invalidated)
        lifecycle.finishSleepPreparation(restored: true)
        lifecycle.didWake()
        XCTAssertTrue(lifecycle.shouldResumeAfterWake)
    }

    func testNegativeLatchedBeforeObserverRetirementCannotBeClearedByRestore() throws {
        let identity = UUID()
        let layout = try DisplayLayout(main: identity, origins: [identity: DisplayOrigin(x: 0, y: 0)])
        let record = try RecoveryRecord(baseline: layout, target: layout)
        var lifecycle = InternalSessionLifecycle()
        lifecycle.didConfirmUserConfiguration()
        try lifecycle.beginReapplication()
        lifecycle.willSleep()
        var candidates = ConnectionCandidateState()
        XCTAssertTrue(candidates.matched(entryID: 42, service: .videoInterface, location: "External"))
        var observing = true
        if observing {
            _ = candidates.invalidate(entryID: 0, terminated: false)
            lifecycle.fail()
        }

        let restored = InternalSleepPreparation.restore(stopObserving: { observing = false }) {
            if observing {
                _ = candidates.invalidate(entryID: 0, terminated: false)
                lifecycle.fail()
            }
            lifecycle.didRestore()
            return record
        }

        XCTAssertEqual(restored, record)
        XCTAssertTrue(candidates.invalidated)
        XCTAssertFalse(observing)
        lifecycle.finishSleepPreparation(restored: true)
        lifecycle.didWake()
        XCTAssertTrue(lifecycle.faulted)
        XCTAssertFalse(lifecycle.shouldResumeAfterWake)
    }

    func testRestoreRetiresObserverAndRethrowsForCallerRecovery() throws {
        enum RestoreFailure: Error, Equatable { case injected }
        var lifecycle = InternalSessionLifecycle()
        lifecycle.didConfirmUserConfiguration()
        try lifecycle.beginReapplication()
        lifecycle.willSleep()
        var observing = true
        var callerEnteredRecovery = false

        XCTAssertThrowsError(try InternalSleepPreparation.restore(stopObserving: { observing = false }) {
            throw RestoreFailure.injected
        }) { error in
            XCTAssertEqual(error as? RestoreFailure, .injected)
            XCTAssertFalse(observing)
            callerEnteredRecovery = true
            lifecycle.finishSleepPreparation(restored: false)
        }

        XCTAssertTrue(callerEnteredRecovery)
        lifecycle.didWake()
        XCTAssertTrue(lifecycle.faulted)
        XCTAssertFalse(lifecycle.shouldResumeAfterWake)
    }

    func testStartupPersistenceFailureDrainsAcceptedSleepOutsideControlQueueBeforeExit() throws {
        let control = DispatchQueue(label: "sleep-test.startup-control")
        let notifications = DispatchQueue(label: "sleep-test.startup-power")
        let accepted = DispatchSemaphore(value: 0)
        let state = SleepPreparationState()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        let identity = UUID()
        let layout = try DisplayLayout(main: identity, origins: [identity: DisplayOrigin(x: 0, y: 0)])
        let record = try RecoveryRecord(baseline: layout, target: layout)
        XCTAssertThrowsError(try InternalSleepPreparation.startSession(on: control, cleanupPower: {
            notifications.sync { state.lock.withLock { state.events.append("power-drained") } }
        }) {
            notifications.async {
                state.lock.withLock { state.lifecycle.willSleep() }
                accepted.signal()
                let restored = InternalSleepPreparation.wait(on: control, alreadyOnQueue: false, deadline: .now() + 2) {
                    state.lock.withLock { state.events.append("queued-recovery") }
                    return false
                }
                state.lock.withLock {
                    state.events.append("ack")
                    state.lifecycle.finishSleepPreparation(restored: restored)
                }
            }
            XCTAssertEqual(accepted.wait(timeout: .now() + 1), .success)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
            _ = try store.apply(record) { XCTFail("failed persistence must precede native writes"); return (layout, nil) }
        })
        state.lock.withLock {
            state.events.append("caller-exit")
            XCTAssertEqual(state.events, ["queued-recovery", "ack", "power-drained", "caller-exit"])
            XCTAssertFalse(state.lifecycle.preparingForSleep)
            XCTAssertTrue(state.lifecycle.beginExitAfterRecovery())
        }
    }

    func testAcknowledgementResumesDeferredStopInsteadOfDroppingQuitIntent() {
        var state = InternalSessionLifecycle()
        state.willSleep()
        state.didRestore()
        state.requestPause()
        XCTAssertFalse(state.beginExitAfterRecovery())
        var events = ["restored", "stop-deferred"]
        events.append("ack")
        state.finishSleepPreparation(restored: true)
        InternalSleepPreparation.complete(restored: true, acknowledged: true, stopping: true,
            stop: { XCTAssertTrue(state.beginExitAfterRecovery()); events.append("exit") },
            resume: { XCTFail("quit intent must not become wake reapplication") })
        XCTAssertEqual(events, ["restored", "stop-deferred", "ack", "exit"])
    }

    func testContinuousElapsedTimeCannotBeHiddenByPausedUptimeOrClockRegression() {
        let samples: [[UInt64]] = [[0, 11_000_000_000], [1, 0]]
        for values in samples {
            let queue = DispatchQueue(label: "sleep-test.continuous-budget")
            let state = SleepPreparationState()
            state.clockValues = values
            XCTAssertFalse(InternalSleepPreparation.wait(
                on: queue, alreadyOnQueue: false, deadline: .now() + 1,
                continuousNow: { state.lock.withLock { state.clockValues.removeFirst() } }
            ) { true })
            queue.sync {}
        }
    }

    func testUnavailableClockKeepsRecoveryQueuedButCannotAuthorizeWake() {
        enum ClockFailure: Error { case injected }
        let queue = DispatchQueue(label: "sleep-test.unavailable-clock")
        let recovered = DispatchSemaphore(value: 0)
        XCTAssertFalse(InternalSleepPreparation.wait(
            on: queue, alreadyOnQueue: false, deadline: .now() + 1,
            continuousNow: { throw ClockFailure.injected }
        ) { recovered.signal(); return true })
        XCTAssertEqual(recovered.wait(timeout: .now() + 1), .success)
    }

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
