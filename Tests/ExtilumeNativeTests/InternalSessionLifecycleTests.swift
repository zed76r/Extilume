import XCTest
@testable import ExtilumeNative

final class InternalSessionLifecycleTests: XCTestCase {
    func testExitWaitsForAllAcceptedPowerAcknowledgements() {
        var state = InternalSessionLifecycle()
        XCTAssertTrue(state.willSleep())
        XCTAssertTrue(state.willSleep())
        state.didRestore()
        XCTAssertFalse(state.beginExitAfterRecovery())
        state.finishSleepPreparation(restored: true)
        XCTAssertFalse(state.beginExitAfterRecovery())
        state.finishSleepPreparation(restored: false)
        XCTAssertTrue(state.beginExitAfterRecovery())
        XCTAssertTrue(state.faulted)
    }

    func testLateSleepAfterExitDecisionCannotQueueRecoveryOrControls() {
        var state = InternalSessionLifecycle()
        state.didRestore()
        XCTAssertTrue(state.beginExitAfterRecovery())
        XCTAssertFalse(state.willSleep())
        XCTAssertFalse(state.preparingForSleep)
        state.didWake()
        XCTAssertFalse(state.permitsControls)
        XCTAssertFalse(state.shouldResumeAfterWake)
        XCTAssertThrowsError(try state.beginReapplication())
    }

    func testSleepBeforeRestoreAndEarlyWakeStillBlockWrites() throws {
        var state = InternalSessionLifecycle()
        state.willSleep()
        XCTAssertFalse(state.permitsControls)
        XCTAssertThrowsError(try state.beginReapplication())
        state.didWake()
        XCTAssertFalse(state.permitsControls)
        XCTAssertFalse(state.shouldResumeAfterWake)
        state.didRestore()
        XCTAssertFalse(state.shouldResumeAfterWake)
        state.finishSleepPreparation(restored: true)
        XCTAssertTrue(state.shouldResumeAfterWake)
        try state.beginReapplication()
        XCTAssertFalse(state.paused)
        XCTAssertFalse(state.shouldResumeAfterWake)
    }

    func testSleepWhileReapplyingRequestsResumeAfterVerifiedRestoration() throws {
        var state = InternalSessionLifecycle()
        state.requestPause()
        state.didRestore()
        try state.beginReapplication()
        state.willSleep()
        state.didRestore()
        state.finishSleepPreparation(restored: true)
        XCTAssertFalse(state.permitsControls)
        state.didWake()
        XCTAssertTrue(state.shouldResumeAfterWake)
    }

    func testManualPauseDoesNotBecomeAnImplicitWakeReapplication() {
        var state = InternalSessionLifecycle()
        state.requestPause()
        state.didRestore()
        state.willSleep()
        state.willSleep()
        state.didRestore()
        state.finishSleepPreparation(restored: true)
        state.finishSleepPreparation(restored: true)
        state.didWake()
        XCTAssertTrue(state.paused)
        XCTAssertTrue(state.permitsControls)
        XCTAssertFalse(state.shouldResumeAfterWake)
    }

    func testConfirmedUserConfigurationRetainsIntentForNextWakeWithoutReapplyingImmediately() {
        var state = InternalSessionLifecycle()
        state.didConfirmUserConfiguration()
        XCTAssertTrue(state.paused)
        state.willSleep()
        XCTAssertFalse(state.permitsControls)
        state.didRestore()
        state.finishSleepPreparation(restored: true)
        state.didWake()
        XCTAssertTrue(state.shouldResumeAfterWake)
        state.fail()
        state.didConfirmUserConfiguration()
        XCTAssertFalse(state.shouldResumeAfterWake)
        XCTAssertTrue(state.faulted)
    }

    func testFaultBeforeDuringOrAfterSleepCannotBeClearedByRestoration() {
        for point in 0..<3 {
            var state = InternalSessionLifecycle()
            if point == 0 { state.fail() }
            state.willSleep()
            if point == 1 { state.fail() }
            state.didRestore()
            state.finishSleepPreparation(restored: true)
            state.didWake()
            if point == 2 { state.fail() }
            XCTAssertTrue(state.faulted)
            XCTAssertFalse(state.permitsControls)
            XCTAssertFalse(state.shouldResumeAfterWake)
            XCTAssertThrowsError(try state.beginReapplication())
        }
    }

    func testSleepRequestDoesNotMaskRealTransactionOrReadbackFailure() {
        for error in [DisplayEnableTransactionError.commitFailed, .unsafeTopology] {
            var state = InternalSessionLifecycle()
            state.willSleep()
            XCTAssertFalse(state.pauseAfterFailure(error, protectionReady: true))
            state.didRestore()
            state.finishSleepPreparation(restored: true)
            state.didWake()
            XCTAssertTrue(state.faulted)
            XCTAssertFalse(state.shouldResumeAfterWake)
        }
    }

    func testOnlyExplicitPauseCancellationWithLiveProtectionCanResume() {
        for ready in [true, false] {
            var state = InternalSessionLifecycle()
            state.willSleep()
            XCTAssertEqual(state.pauseAfterFailure(InternalControlCancellation.pauseRequested, protectionReady: ready), ready)
            state.didRestore()
            state.finishSleepPreparation(restored: ready)
            state.didWake()
            XCTAssertEqual(state.shouldResumeAfterWake, ready)
        }
        var state = InternalSessionLifecycle()
        XCTAssertFalse(state.pauseAfterFailure(InternalControlCancellation.pauseRequested, protectionReady: true))
        XCTAssertTrue(state.faulted)
    }
}
