import XCTest
@testable import ExtilumeNative

final class InternalSessionLifecycleTests: XCTestCase {
    func testSleepAcknowledgementDoesNotRequireOrClaimRestoration() throws {
        var state = InternalSessionLifecycle()
        XCTAssertTrue(state.willSleep())
        state.finishSleepPreparation(acknowledged: true)
        XCTAssertFalse(state.faulted)
        XCTAssertFalse(state.paused)
        XCTAssertFalse(state.permitsRecovery)
        XCTAssertFalse(state.permitsControls)
        state.didWake()
        XCTAssertTrue(state.shouldRecoverAfterWake)
        XCTAssertFalse(state.shouldResumeAfterWake)
        state.didRestore()
        XCTAssertTrue(state.shouldResumeAfterWake)
        try state.beginReapplication()
        XCTAssertFalse(state.paused)
    }

    func testEarlyWakeAndDuplicateSleepWaitForAllAcksAndFreshRecovery() {
        var state = InternalSessionLifecycle()
        state.willSleep()
        let epoch = state.sleepEpoch
        state.willSleep()
        XCTAssertEqual(state.sleepEpoch, epoch)
        state.didWake()
        state.didRestore()
        XCTAssertFalse(state.paused)
        state.finishSleepPreparation(acknowledged: true)
        XCTAssertFalse(state.permitsRecovery)
        state.finishSleepPreparation(acknowledged: true)
        XCTAssertTrue(state.shouldRecoverAfterWake)
        XCTAssertFalse(state.shouldResumeAfterWake)
        state.didRestore()
        XCTAssertTrue(state.shouldResumeAfterWake)
        state.willSleep()
        XCTAssertNotEqual(state.sleepEpoch, epoch)
        XCTAssertFalse(state.shouldResumeAfterWake)
    }

    func testManualPauseNeverBecomesImplicitWakeReapplication() {
        for restoredBeforeSleep in [true, false] {
            var state = InternalSessionLifecycle()
            state.requestPause()
            if restoredBeforeSleep { state.didRestore() }
            state.willSleep()
            state.finishSleepPreparation(acknowledged: true)
            state.didWake()
            state.didRestore()
            XCTAssertTrue(state.paused)
            XCTAssertFalse(state.shouldResumeAfterWake)
        }
    }

    func testStopBeforeOrDuringSleepKeepsRecoveryButRevokesReapplication() {
        for stopBeforeSleep in [true, false] {
            var state = InternalSessionLifecycle()
            if stopBeforeSleep { state.requestStop() }
            state.willSleep()
            let epoch = state.sleepEpoch
            if !stopBeforeSleep { state.requestStop() }
            state.finishSleepPreparation(acknowledged: true)
            XCTAssertFalse(state.beginExitAfterRecovery(verifiedSleepEpoch: epoch, powerAllowsExit: { true }))
            state.didWake()
            XCTAssertTrue(state.permitsRecovery)
            state.didRestore()
            XCTAssertTrue(state.stopRequested)
            XCTAssertFalse(state.shouldResumeAfterWake)
            XCTAssertThrowsError(try state.beginReapplication())
            XCTAssertTrue(state.beginExitAfterRecovery(verifiedSleepEpoch: epoch, powerAllowsExit: { true }))
            XCTAssertFalse(state.willSleep())
        }
    }

    func testFullSleepDuringExitDrainRejectsOldRecoveryBeforeConsumingPowerGate() {
        var state = InternalSessionLifecycle()
        let gate = InternalPowerGate()
        gate.didRegister()
        state.requestStop()
        let verifiedBeforeDrain = state.sleepEpoch
        state.didRestore()

        XCTAssertTrue(gate.willSleep())
        XCTAssertTrue(state.willSleep())
        gate.didAcknowledgeSleep(true)
        state.finishSleepPreparation(acknowledged: true)
        XCTAssertTrue(gate.didWake())
        state.didWake()
        XCTAssertTrue(gate.isReady && state.permitsRecovery)

        var powerChecks = 0
        XCTAssertFalse(state.beginExitAfterRecovery(verifiedSleepEpoch: verifiedBeforeDrain) {
            powerChecks += 1
            return gate.beginExitAfterRecovery()
        })
        XCTAssertEqual(powerChecks, 0)
        XCTAssertTrue(gate.isReady)
        XCTAssertFalse(state.exiting)
        XCTAssertTrue(state.stopRequested && state.shouldRecoverAfterWake)
        XCTAssertFalse(state.permitsControls)

        let verifiedAfterWake = state.sleepEpoch
        state.didRestore()
        XCTAssertTrue(state.beginExitAfterRecovery(verifiedSleepEpoch: verifiedAfterWake) {
            gate.beginExitAfterRecovery()
        })
        XCTAssertTrue(state.exiting)
        XCTAssertFalse(gate.isReady)
    }

    func testBusyPowerGateDoesNotConsumeLifecycleExit() throws {
        var state = InternalSessionLifecycle()
        let gate = InternalPowerGate()
        gate.didRegister()
        state.requestStop()
        let verifiedEpoch = state.sleepEpoch
        state.didRestore()
        try gate.perform {
            XCTAssertFalse(state.beginExitAfterRecovery(verifiedSleepEpoch: verifiedEpoch) {
                gate.beginExitAfterRecovery()
            })
            XCTAssertFalse(state.exiting)
        }
        XCTAssertTrue(state.beginExitAfterRecovery(verifiedSleepEpoch: verifiedEpoch) {
            gate.beginExitAfterRecovery()
        })
    }

    func testConfirmedUserConfigurationRetainsWakeIntentWithoutImmediateApplication() {
        var state = InternalSessionLifecycle()
        state.didConfirmUserConfiguration()
        XCTAssertTrue(state.paused)
        state.willSleep()
        state.finishSleepPreparation(acknowledged: true)
        state.didWake()
        XCTAssertFalse(state.shouldResumeAfterWake)
        state.didRestore()
        XCTAssertTrue(state.shouldResumeAfterWake)
    }

    func testFaultCannotBeClearedByWakeRestorationOrUserConfirmation() {
        for point in 0..<3 {
            var state = InternalSessionLifecycle()
            if point == 0 { state.fail() }
            state.willSleep()
            if point == 1 { state.fail() }
            state.finishSleepPreparation(acknowledged: true)
            state.didWake()
            if point == 2 { state.fail() }
            XCTAssertTrue(state.permitsRecovery)
            state.didRestore()
            state.didConfirmUserConfiguration()
            XCTAssertTrue(state.faulted)
            XCTAssertFalse(state.shouldResumeAfterWake)
        }
    }

    func testRealNativeFailureIsNotHiddenBySleepCancellation() {
        for error in [DisplayEnableTransactionError.commitFailed, .unsafeTopology] {
            var state = InternalSessionLifecycle()
            state.willSleep()
            XCTAssertFalse(state.pauseAfterFailure(error, protectionReady: true))
            state.finishSleepPreparation(acknowledged: true)
            state.didWake()
            state.didRestore()
            XCTAssertTrue(state.faulted)
            XCTAssertFalse(state.shouldResumeAfterWake)
        }
    }

    func testOnlyExpectedCancellationWithLiveProtectionKeepsIntent() {
        for ready in [true, false] {
            let errors: [Error] = [InternalControlCancellation.pauseRequested, InternalPowerGateError.suspended]
            for error in errors {
                var state = InternalSessionLifecycle()
                state.willSleep()
                XCTAssertEqual(state.pauseAfterFailure(error, protectionReady: ready), ready)
                state.finishSleepPreparation(acknowledged: true)
                state.didWake()
                state.didRestore()
                XCTAssertEqual(state.shouldResumeAfterWake, ready)
            }
        }
    }

    func testSleepWhileRegisteringObserverCancelsManualAndScheduledReapplication() {
        for stillCurrent in [true, false] {
            var state = InternalSessionLifecycle()
            state.didConfirmUserConfiguration()
            XCTAssertTrue(state.paused && state.permitsControls)
            // 观察启动期间进入睡眠；父入口在同一授权锁内检查代次并开始重应用。
            state.willSleep()
            do {
                try state.beginReapplication(isCurrent: stillCurrent)
                XCTFail("sleep must revoke the queued application")
            } catch {
                XCTAssertEqual(error as? InternalControlCancellation, .pauseRequested)
                XCTAssertTrue(state.pauseAfterFailure(error, protectionReady: true))
            }
            state.finishSleepPreparation(acknowledged: true)
            state.didWake()
            state.didRestore()
            XCTAssertFalse(state.faulted)
            XCTAssertTrue(state.shouldResumeAfterWake)
        }
    }

    func testWakeStabilityRetryIsBoundedAndDoesNotExcuseRealFailures() {
        var state = InternalSessionLifecycle()
        state.willSleep()
        state.finishSleepPreparation(acknowledged: true)
        state.didWake()
        XCTAssertEqual(internalWakeVerificationRetryDelay(error: GuardError.unstable, attempt: 0, lifecycle: state), 0.3)
        XCTAssertEqual(internalWakeVerificationRetryDelay(error: SnapshotWitnessError.internalStateChanged, attempt: 1, lifecycle: state), 0.3)
        XCTAssertNil(internalWakeVerificationRetryDelay(error: GuardError.unstable, attempt: 2, lifecycle: state))
        XCTAssertNil(internalWakeVerificationRetryDelay(error: DisplayEnableTransactionError.commitFailed, attempt: 0, lifecycle: state))
        XCTAssertNil(internalWakeVerificationRetryDelay(error: GuardError.identity, attempt: 0, lifecycle: state))
        state.fail()
        XCTAssertNil(internalWakeVerificationRetryDelay(error: GuardError.unstable, attempt: 0, lifecycle: state))
    }

    func testWakeWitnessDeadlineSharesOriginalBudgetAndRejectsUnknownOrExpiredTime() {
        XCTAssertEqual(internalWakeWitnessDeadline(now: 1_000, elapsed: 0), 10_000_001_000)
        XCTAssertEqual(internalWakeWitnessDeadline(now: 1_000_001_000, elapsed: 1_000_000_000), 10_000_001_000)
        XCTAssertNil(internalWakeWitnessDeadline(now: 1_000, elapsed: nil))
        XCTAssertNil(internalWakeWitnessDeadline(now: 1_000, elapsed: 10_000_000_000))
        XCTAssertNil(internalWakeWitnessDeadline(now: UInt64.max, elapsed: 0))
    }

    func testWakeInformationWaitRequiresAutomaticIntentAndKnownRemainingBudget() throws {
        var active = InternalSessionLifecycle()
        active.willSleep()
        active.finishSleepPreparation(acknowledged: true)
        active.didWake()
        let unavailable = SnapshotWitnessError.internalInformationUnavailable
        XCTAssertEqual(internalWakeInformationRetryDelay(error: unavailable, elapsed: 0, lifecycle: active), 0.3)
        XCTAssertNil(internalWakeInformationRetryDelay(error: unavailable, elapsed: nil, lifecycle: active))
        XCTAssertNil(internalWakeInformationRetryDelay(error: unavailable, elapsed: 10_000_000_000, lifecycle: active))
        XCTAssertNil(internalWakeInformationRetryDelay(error: SnapshotWitnessError.internalStateChanged, elapsed: 0, lifecycle: active))
        XCTAssertNil(internalWakeInformationRetryDelay(error: SnapshotWitnessError.communicationFailed, elapsed: 0, lifecycle: active))

        var manuallyPaused = InternalSessionLifecycle()
        manuallyPaused.requestPause()
        manuallyPaused.willSleep()
        manuallyPaused.finishSleepPreparation(acknowledged: true)
        manuallyPaused.didWake()
        XCTAssertTrue(manuallyPaused.shouldRecoverAfterWake)
        XCTAssertFalse(manuallyPaused.resumeAfterWake)
        XCTAssertNil(internalWakeInformationRetryDelay(error: unavailable, elapsed: 0, lifecycle: manuallyPaused))

        let remaining = try XCTUnwrap(internalWakeInformationRetryDelay(
            error: unavailable, elapsed: 9_900_000_000, lifecycle: active
        ))
        XCTAssertEqual(remaining, 0.1, accuracy: 0.000_000_1)
    }

    func testWakeRecoveryDeadlineIgnoresOldEpochAndLatchesUnknownOrExpiredBudget() {
        var active = InternalSessionLifecycle()
        active.willSleep()
        active.finishSleepPreparation(acknowledged: true)
        active.didWake()
        let oldEpoch = active.sleepEpoch
        active.willSleep()
        active.finishSleepPreparation(acknowledged: true)
        active.didWake()
        XCTAssertNotEqual(active.sleepEpoch, oldEpoch)
        XCTAssertEqual(internalWakeRecoveryDeadlineDecision(epoch: oldEpoch, lifecycle: &active, elapsed: nil), .stale)
        XCTAssertFalse(active.faulted)

        var unknownBudget = InternalSessionLifecycle()
        unknownBudget.willSleep()
        unknownBudget.finishSleepPreparation(acknowledged: true)
        unknownBudget.didWake()
        XCTAssertEqual(internalWakeRecoveryDeadlineDecision(
            epoch: unknownBudget.sleepEpoch, lifecycle: &unknownBudget, elapsed: nil
        ), .expired)
        XCTAssertTrue(unknownBudget.faulted)
        XCTAssertFalse(unknownBudget.resumeAfterWake)

        var expiredBudget = InternalSessionLifecycle()
        expiredBudget.willSleep()
        expiredBudget.finishSleepPreparation(acknowledged: true)
        expiredBudget.didWake()
        XCTAssertEqual(internalWakeRecoveryDeadlineDecision(
            epoch: expiredBudget.sleepEpoch, lifecycle: &expiredBudget, elapsed: 10_000_000_000
        ), .expired)
        XCTAssertTrue(expiredBudget.faulted)
    }

    func testWakeRecoveryDeadlineRunsWhileManuallyPausedOrAwaitingSleepAcknowledgement() {
        var manuallyPaused = InternalSessionLifecycle()
        manuallyPaused.requestPause()
        manuallyPaused.willSleep()
        manuallyPaused.finishSleepPreparation(acknowledged: true)
        manuallyPaused.didWake()
        XCTAssertFalse(manuallyPaused.resumeAfterWake)
        let manualDecision = internalWakeRecoveryDeadlineDecision(
            epoch: manuallyPaused.sleepEpoch, lifecycle: &manuallyPaused, elapsed: 1
        )
        guard case .wait(let manualRemaining) = manualDecision else {
            return XCTFail("manual pause should still retain the wake recovery deadline")
        }
        XCTAssertEqual(manualRemaining, 9.999_999_999, accuracy: 0.000_000_001)

        var awaitingAcknowledgement = InternalSessionLifecycle()
        awaitingAcknowledgement.willSleep()
        awaitingAcknowledgement.didWake()
        XCTAssertFalse(awaitingAcknowledgement.permitsRecovery)
        let acknowledgementDecision = internalWakeRecoveryDeadlineDecision(
            epoch: awaitingAcknowledgement.sleepEpoch, lifecycle: &awaitingAcknowledgement, elapsed: 1
        )
        guard case .wait(let acknowledgementRemaining) = acknowledgementDecision else {
            return XCTFail("pending sleep acknowledgement should retain the wake recovery deadline")
        }
        XCTAssertEqual(acknowledgementRemaining, 9.999_999_999, accuracy: 0.000_000_001)
    }

    func testAcknowledgementFailureRemainsFaultAfterWake() {
        var state = InternalSessionLifecycle()
        state.willSleep()
        state.finishSleepPreparation(acknowledged: false)
        state.didWake()
        state.didRestore()
        XCTAssertTrue(state.faulted)
        XCTAssertFalse(state.shouldResumeAfterWake)
    }
}
