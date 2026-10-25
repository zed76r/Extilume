import Foundation
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

final class InternalRecoveryClockTests: XCTestCase {
    func testSubtractsProvenSleepAndIncludesDelayAfterWake() {
        let fixture = FakeRecoveryClock()
        let clock = recoveryClock(fixture)
        clock.setBootSession(bootA)
        fixture.enqueueNow(100)
        clock.start()
        clock.start()

        fixture.enqueueSample(before: 112, awake: 112, after: 112)
        fixture.enqueueNow(112)
        clock.willSleep()
        fixture.enqueueNow(212)
        fixture.enqueueSample(before: 220, awake: 120, after: 220)
        clock.willSleep()
        clock.didWake()

        fixture.enqueueNow(250)
        XCTAssertEqual(clock.elapsedNanoseconds(), 52)
    }

    func testWakeObservationStartsBudgetAfterProvenSleepWithoutPriorFault() {
        let fixture = FakeRecoveryClock()
        let clock = recoveryClock(fixture)
        clock.setBootSession(bootA)
        fixture.enqueueSample(before: 112, awake: 112, after: 112)
        fixture.enqueueNow(112)
        clock.willSleep()

        // didWake settles any earlier cycle; this new cycle begins at the observed wake time.
        clock.didWake()
        clock.start(at: 212)
        fixture.enqueueNow(262)
        XCTAssertEqual(clock.elapsedNanoseconds(), 50)
    }

    func testSleepNotificationsWithoutMeasuredPauseDoNotReduceElapsed() {
        let fixture = FakeRecoveryClock()
        let clock = recoveryClock(fixture)
        clock.setBootSession(bootA)
        fixture.enqueueNow(100)
        clock.start()
        fixture.enqueueSample(before: 112, awake: 112, after: 112)
        fixture.enqueueNow(112)
        clock.willSleep()
        fixture.enqueueNow(212)
        fixture.enqueueSample(before: 220, awake: 220, after: 220)
        clock.didWake()

        fixture.enqueueNow(250)
        XCTAssertEqual(clock.elapsedNanoseconds(), 150)
    }

    func testSleepThatStartedBeforeFaultIsNotSubtracted() {
        let fixture = FakeRecoveryClock()
        let clock = recoveryClock(fixture)
        clock.setBootSession(bootA)
        fixture.enqueueSample(before: 112, awake: 112, after: 112)
        fixture.enqueueNow(112)
        clock.willSleep()

        fixture.enqueueNow(150)
        clock.start()
        fixture.enqueueNow(212)
        fixture.enqueueSample(before: 220, awake: 120, after: 220)
        clock.didWake()

        fixture.enqueueNow(250)
        XCTAssertEqual(clock.elapsedNanoseconds(), 100)
    }

    func testSleepCompletedBeforeStartIsNotRetainedAsEvidence() {
        let fixture = FakeRecoveryClock()
        let clock = recoveryClock(fixture)
        clock.setBootSession(bootA)
        fixture.enqueueSample(before: 112, awake: 112, after: 112)
        fixture.enqueueNow(112)
        clock.willSleep()
        clock.didWake()

        fixture.enqueueNow(300)
        clock.start()
        fixture.enqueueNow(350)
        XCTAssertEqual(clock.elapsedNanoseconds(), 50)
    }

    func testBootChangeInvalidatesTimingWithoutRestartingFault() {
        let fixture = FakeRecoveryClock()
        let clock = recoveryClock(fixture)
        clock.setBootSession(bootA)
        fixture.enqueueNow(100)
        clock.start()
        fixture.enqueueSample(before: 112, awake: 112, after: 112)
        fixture.enqueueNow(112)
        clock.willSleep()
        fixture.enqueueNow(212)
        fixture.enqueueSample(before: 220, awake: 120, after: 220)
        clock.didWake()

        clock.setBootSession(bootB)
        fixture.enqueueNow(250)
        clock.start()
        XCTAssertNil(clock.elapsedNanoseconds())
    }

    func testResetClearsStartAndOldSleepIntervals() {
        let fixture = FakeRecoveryClock()
        let clock = recoveryClock(fixture)
        clock.setBootSession(bootA)
        fixture.enqueueNow(100)
        clock.start()
        fixture.enqueueSample(before: 112, awake: 112, after: 112)
        fixture.enqueueNow(112)
        clock.willSleep()
        fixture.enqueueNow(212)
        fixture.enqueueSample(before: 220, awake: 120, after: 220)
        clock.didWake()

        clock.reset()
        XCTAssertNil(clock.elapsedNanoseconds())
        fixture.enqueueNow(250)
        clock.start()
        fixture.enqueueNow(300)
        XCTAssertEqual(clock.elapsedNanoseconds(), 50)
    }

    func testCriticalClockReadFailureOrRollbackReturnsNil() {
        let failedStartFixture = FakeRecoveryClock()
        let failedStartClock = recoveryClock(failedStartFixture)
        failedStartFixture.enqueueNowFailure()
        failedStartClock.start()
        failedStartFixture.enqueueNow(200)
        failedStartClock.start()
        XCTAssertNil(failedStartClock.elapsedNanoseconds())

        let failedNowFixture = FakeRecoveryClock()
        let failedNowClock = recoveryClock(failedNowFixture)
        failedNowFixture.enqueueNow(100)
        failedNowClock.start()
        failedNowFixture.enqueueNowFailure()
        XCTAssertNil(failedNowClock.elapsedNanoseconds())

        let rollbackFixture = FakeRecoveryClock()
        let rollbackClock = recoveryClock(rollbackFixture)
        rollbackFixture.enqueueNow(100)
        rollbackClock.start()
        rollbackFixture.enqueueNow(99)
        XCTAssertNil(rollbackClock.elapsedNanoseconds())
    }

    func testInvalidSleepEvidenceDoesNotReduceKnownTotalElapsed() {
        let fixture = FakeRecoveryClock()
        let clock = recoveryClock(fixture)
        clock.setBootSession(bootA)
        fixture.enqueueNow(100)
        clock.start()
        fixture.enqueueSampleFailure()
        clock.willSleep()
        fixture.enqueueNow(250)
        XCTAssertEqual(clock.elapsedNanoseconds(), 150)
    }

    func testEarlierPendingOriginWinsAndLaterOriginDoesNotExtendIt() {
        let fixture = FakeRecoveryClock()
        let clock = recoveryClock(fixture)

        clock.start(at: 300)
        clock.start(at: 100)
        clock.start(at: 250)
        fixture.enqueueNow(400)

        XCTAssertEqual(clock.elapsedNanoseconds(), 300)
    }

    func testMissingOriginAndPreviouslyInvalidOriginCannotBeRepaired() {
        let missingFixture = FakeRecoveryClock()
        let missingClock = recoveryClock(missingFixture)
        missingClock.start(at: nil)
        missingClock.start(at: 100)
        missingFixture.enqueueNow(200)
        XCTAssertNil(missingClock.elapsedNanoseconds())

        let failedFixture = FakeRecoveryClock()
        let failedClock = recoveryClock(failedFixture)
        failedFixture.enqueueNowFailure()
        failedClock.start()
        failedClock.start(at: 100)
        failedFixture.enqueueNow(200)
        XCTAssertNil(failedClock.elapsedNanoseconds())
    }

    func testResetAllowsANewPendingOriginAfterAnUnprovableStart() {
        let fixture = FakeRecoveryClock()
        let clock = recoveryClock(fixture)
        clock.start(at: nil)
        clock.start(at: 100)
        XCTAssertNil(clock.elapsedNanoseconds())

        clock.reset()
        clock.start(at: 300)
        fixture.enqueueNow(360)
        XCTAssertEqual(clock.elapsedNanoseconds(), 60)
    }

    private var bootA: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! }
    private var bootB: UUID { UUID(uuidString: "00000000-0000-0000-0000-000000000002")! }

    private func recoveryClock(_ fixture: FakeRecoveryClock) -> InternalRecoveryClock {
        InternalRecoveryClock(
            now: { try fixture.readNow() },
            sample: { try fixture.readSample(bootSession: $0) }
        )
    }
}

private enum FakeClockReadError: Error {
    case failed
}

private enum FakeSampleRead {
    case values(before: UInt64, awake: UInt64, after: UInt64)
    case failed
}

private final class FakeRecoveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var nowReads: [Result<UInt64, FakeClockReadError>] = []
    private var sampleReads: [FakeSampleRead] = []

    func enqueueNow(_ value: UInt64) {
        lock.lock()
        nowReads.append(.success(value))
        lock.unlock()
    }

    func enqueueNowFailure() {
        lock.lock()
        nowReads.append(.failure(.failed))
        lock.unlock()
    }

    func enqueueSample(before: UInt64, awake: UInt64, after: UInt64) {
        lock.lock()
        sampleReads.append(.values(before: before, awake: awake, after: after))
        lock.unlock()
    }

    func enqueueSampleFailure() {
        lock.lock()
        sampleReads.append(.failed)
        lock.unlock()
    }

    func readNow() throws -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        guard !nowReads.isEmpty else { throw FakeClockReadError.failed }
        return try nowReads.removeFirst().get()
    }

    func readSample(bootSession: UUID) throws -> RecoveryClockSample {
        lock.lock()
        defer { lock.unlock() }
        guard !sampleReads.isEmpty else { throw FakeClockReadError.failed }
        switch sampleReads.removeFirst() {
        case let .values(before, awake, after):
            return try RecoveryClockSample(
                bootSession: bootSession,
                continuousBeforeNanoseconds: before,
                awakeNanoseconds: awake,
                continuousAfterNanoseconds: after
            )
        case .failed:
            throw FakeClockReadError.failed
        }
    }
}
