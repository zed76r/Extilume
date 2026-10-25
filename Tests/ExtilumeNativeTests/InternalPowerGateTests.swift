import Dispatch
import Foundation
import XCTest
@testable import ExtilumeNative

final class InternalPowerGateTests: XCTestCase {
    func testThrowingWrapperReleasesInFlightFlagAndPreservesSleepGate() throws {
        enum Failure: Error { case rejected }
        let gate = registeredGate()
        XCTAssertThrowsError(try gate.perform { throw Failure.rejected })
        XCTAssertEqual(try gate.perform { 7 }, 7)
        XCTAssertThrowsError(try gate.perform {
            _ = gate.willSleep()
            gate.didAcknowledgeSleep(true)
            throw Failure.rejected
        })
        XCTAssertThrowsError(try gate.perform { 8 }) {
            XCTAssertEqual($0 as? InternalPowerGateError, .suspended)
        }
    }

    func testSleepAndAcknowledgementDoNotWaitForInFlightCall() {
        let gate = registeredGate()
        let callStarted = DispatchSemaphore(value: 0)
        let releaseCall = DispatchSemaphore(value: 0)
        let callFinished = DispatchSemaphore(value: 0)
        let result = LockedTestInt()

        DispatchQueue.global().async {
            if let value = try? gate.perform({
                callStarted.signal()
                _ = releaseCall.wait(timeout: .now() + 5)
                return 73
            }) {
                result.set(value)
            }
            callFinished.signal()
        }

        let callEntered = callStarted.wait(timeout: .now() + 2) == .success
        XCTAssertTrue(callEntered)

        let sleepFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = gate.willSleep()
            sleepFinished.signal()
        }
        let sleepReturnedBeforeCall = sleepFinished.wait(timeout: .now() + 2) == .success
        XCTAssertTrue(sleepReturnedBeforeCall)

        let acknowledgementFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            gate.didAcknowledgeSleep(true)
            acknowledgementFinished.signal()
        }
        let acknowledgementReturnedBeforeCall = acknowledgementFinished.wait(timeout: .now() + 2) == .success
        XCTAssertTrue(acknowledgementReturnedBeforeCall)

        XCTAssertThrowsError(try gate.perform { XCTFail("sleeping gate admitted a call"); return 0 }) {
            XCTAssertEqual($0 as? InternalPowerGateError, .suspended)
        }
        XCTAssertFalse(gate.beginExitAfterRecovery())

        releaseCall.signal()
        XCTAssertEqual(callFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(result.value, 73)
        XCTAssertTrue(gate.didWake())
        XCTAssertNoThrow(try gate.check())
    }

    func testWakeDoesNotClearPendingAcknowledgements() {
        let gate = registeredGate()
        XCTAssertTrue(gate.willSleep())
        XCTAssertTrue(gate.willSleep())

        XCTAssertThrowsError(try gate.check()) {
            XCTAssertEqual($0 as? InternalPowerGateError, .suspended)
        }
        XCTAssertFalse(gate.beginExitAfterRecovery())
        XCTAssertTrue(gate.didWake())
        XCTAssertThrowsError(try gate.check()) {
            XCTAssertEqual($0 as? InternalPowerGateError, .suspended)
        }

        gate.didAcknowledgeSleep(true)
        XCTAssertThrowsError(try gate.perform { XCTFail("pending acknowledgement admitted a call"); return 0 }) {
            XCTAssertEqual($0 as? InternalPowerGateError, .suspended)
        }
        gate.didAcknowledgeSleep(true)
        XCTAssertNoThrow(try gate.check())
        XCTAssertFalse(gate.didWake())
    }

    func testSleepBeforeRegistrationSurvivesRegistration() {
        let gate = InternalPowerGate()
        assertUnavailable(gate)
        XCTAssertTrue(gate.willSleep())
        assertUnavailable(gate)
        gate.didRegister()
        XCTAssertThrowsError(try gate.check()) {
            XCTAssertEqual($0 as? InternalPowerGateError, .suspended)
        }
        XCTAssertTrue(gate.didWake())
        gate.didAcknowledgeSleep(true)
        XCTAssertNoThrow(try gate.check())
    }

    func testAcknowledgementFailureAndUnderflowPermanentlyFailContext() {
        let failedAcknowledgement = registeredGate()
        XCTAssertTrue(failedAcknowledgement.willSleep())
        failedAcknowledgement.didAcknowledgeSleep(false)
        XCTAssertTrue(failedAcknowledgement.didWake())
        assertUnavailable(failedAcknowledgement)

        let underflow = registeredGate()
        underflow.didAcknowledgeSleep(true)
        assertUnavailable(underflow)
    }

    func testExitRejectsLateSleepAndRequiresNoInFlightCall() {
        let inFlight = registeredGate()
        let callStarted = DispatchSemaphore(value: 0)
        let releaseCall = DispatchSemaphore(value: 0)
        let callFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = try? inFlight.perform {
                callStarted.signal()
                _ = releaseCall.wait(timeout: .now() + 5)
            }
            callFinished.signal()
        }

        let callEntered = callStarted.wait(timeout: .now() + 2) == .success
        XCTAssertTrue(callEntered)
        XCTAssertFalse(inFlight.beginExitAfterRecovery())
        releaseCall.signal()
        XCTAssertEqual(callFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(inFlight.beginExitAfterRecovery())
        XCTAssertFalse(inFlight.willSleep())
        assertUnavailable(inFlight)
    }

    func testRegistrationRacingSleepCannotClearSleepingState() {
        for _ in 0..<32 {
            let gate = InternalPowerGate()
            let start = DispatchSemaphore(value: 0)
            let finished = DispatchGroup()

            finished.enter()
            DispatchQueue.global().async {
                _ = start.wait(timeout: .now() + 2)
                gate.didRegister()
                finished.leave()
            }
            finished.enter()
            DispatchQueue.global().async {
                _ = start.wait(timeout: .now() + 2)
                _ = gate.willSleep()
                finished.leave()
            }
            start.signal()
            start.signal()

            XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
            XCTAssertThrowsError(try gate.check()) {
                XCTAssertEqual($0 as? InternalPowerGateError, .suspended)
            }
        }
    }

    func testConcurrentNativeAdmissionIsRejectedWithoutCancelingFirstCall() {
        let gate = registeredGate()
        let callStarted = DispatchSemaphore(value: 0)
        let releaseCall = DispatchSemaphore(value: 0)
        let callFinished = DispatchSemaphore(value: 0)
        let result = LockedTestInt()

        DispatchQueue.global().async {
            if let value = try? gate.perform({
                callStarted.signal()
                _ = releaseCall.wait(timeout: .now() + 5)
                return 19
            }) {
                result.set(value)
            }
            callFinished.signal()
        }

        let callEntered = callStarted.wait(timeout: .now() + 2) == .success
        XCTAssertTrue(callEntered)
        XCTAssertThrowsError(try gate.perform { XCTFail("concurrent call was admitted"); return 0 }) {
            XCTAssertEqual($0 as? InternalPowerGateError, .concurrentCall)
        }

        releaseCall.signal()
        XCTAssertEqual(callFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(result.value, 19)
        XCTAssertNoThrow(try gate.check())
    }

    private func registeredGate() -> InternalPowerGate {
        let gate = InternalPowerGate()
        gate.didRegister()
        return gate
    }

    private func assertUnavailable(_ gate: InternalPowerGate, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try gate.check(), file: file, line: line) {
            XCTAssertEqual($0 as? InternalPowerGateError, .unavailable, file: file, line: line)
        }
        XCTAssertThrowsError(try gate.perform { XCTFail("failed context admitted a call", file: file, line: line); return 0 }, file: file, line: line) {
            XCTAssertEqual($0 as? InternalPowerGateError, .unavailable, file: file, line: line)
        }
    }
}

private final class LockedTestInt: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = -1

    func set(_ value: Int) {
        lock.lock()
        storedValue = value
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }
}
