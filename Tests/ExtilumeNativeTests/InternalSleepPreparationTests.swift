import XCTest
import ExtilumeCore
@testable import ExtilumeNative

final class InternalSleepPreparationTests: XCTestCase {
    private enum Injected: Error { case failure }

    func testFailedStartupCleansPowerOutsideControlQueue() {
        let queue = DispatchQueue(label: "test.sleep-startup")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        var cleaned = false
        XCTAssertThrowsError(try InternalSleepPreparation.startSession(on: queue, cleanupPower: {
            XCTAssertNil(DispatchQueue.getSpecific(key: key))
            cleaned = true
        }, operation: { throw Injected.failure }))
        XCTAssertTrue(cleaned)
    }

    func testSleepingRecoveryDoesNotDrainObserverOrRunDisplayOperation() throws {
        let gate = InternalPowerGate()
        gate.didRegister()
        gate.willSleep()
        gate.didAcknowledgeSleep(true)
        XCTAssertThrowsError(try InternalSleepPreparation.restore(checkAccess: { try gate.check() }, stopObserving: {
            XCTFail("sleeping must not start recovery")
        }, operation: { throw Injected.failure })) { error in
            XCTAssertEqual(error as? InternalPowerGateError, .suspended)
        }
    }

    func testSleepDuringObserverDrainDefersDisplayOperation() {
        let gate = InternalPowerGate()
        gate.didRegister()
        XCTAssertThrowsError(try InternalSleepPreparation.restore(checkAccess: { try gate.check() }, stopObserving: {
            gate.willSleep()
        }, operation: {
            XCTFail("drain cannot bypass a new sleep")
            throw Injected.failure
        }))
    }

    func testAwakeRecoveryDrainsBeforeWriteAndPropagatesRealFailure() {
        var events: [String] = []
        XCTAssertThrowsError(try InternalSleepPreparation.restore(stopObserving: {
            events.append("drain")
        }, operation: {
            events.append("restore")
            throw Injected.failure
        }))
        XCTAssertEqual(events, ["drain", "restore"])
    }

    func testNegativeEventBeforeDrainStaysLatchedAfterRecovery() throws {
        let identity = UUID()
        let layout = try DisplayLayout(main: identity, origins: [identity: DisplayOrigin(x: 0, y: 0)])
        let record = try RecoveryRecord(baseline: layout, target: layout)
        var lifecycle = InternalSessionLifecycle()
        lifecycle.fail()
        let restored = try InternalSleepPreparation.restore(stopObserving: {}) {
            lifecycle.didRestore()
            return record
        }
        XCTAssertEqual(restored, record)
        XCTAssertTrue(lifecycle.faulted)
        XCTAssertFalse(lifecycle.shouldResumeAfterWake)
    }
}
