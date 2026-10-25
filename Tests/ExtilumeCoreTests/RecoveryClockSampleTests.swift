import XCTest
@testable import ExtilumeCore

final class RecoveryClockSampleTests: XCTestCase {
    func testUnknownBootCannotAuthorizeSleepDeduction() {
        XCTAssertThrowsError(try RecoveryClockSample(
            bootSession: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            continuousBeforeNanoseconds: 1, awakeNanoseconds: 1, continuousAfterNanoseconds: 1
        ))
    }

    func testCaptureBracketsAwakeClockWithContinuousClock() throws {
        var continuous = [100, 120]
        var reads: [String] = []
        let session = UUID()
        let sample = try RecoveryClockSample.capture(
            bootSession: session,
            readContinuous: {
                reads.append("continuous")
                return UInt64(continuous.removeFirst())
            },
            readAwake: {
                reads.append("awake")
                return 110
            }
        )

        XCTAssertEqual(reads, ["continuous", "awake", "continuous"])
        XCTAssertEqual(sample.bootSession, session)
        XCTAssertEqual(sample.continuousBeforeNanoseconds, 100)
        XCTAssertEqual(sample.awakeNanoseconds, 110)
        XCTAssertEqual(sample.continuousAfterNanoseconds, 120)
        XCTAssertEqual(sample.samplingUncertaintyNanoseconds, 20)
        XCTAssertEqual(try JSONDecoder().decode(RecoveryClockSample.self, from: JSONEncoder().encode(sample)), sample)
    }

    func testSleepBoundsIncludeBothSamplingUncertainties() throws {
        let session = UUID()
        let before = try sample(session, 4, 5, 7)
        let after = try sample(session, 20, 11, 23)
        let powerEvent = RecoveryPowerEventEvidence(
            bootSession: session, willSleepAtNanoseconds: 8, didWakeAtNanoseconds: 16
        )

        let bounds = RecoveryClockSample.provenSleepBounds(
            from: before,
            to: after,
            faultAt: 1,
            latestFaultAt: 3,
            restoredAt: 24,
            powerEvent: powerEvent
        )

        XCTAssertEqual(bounds?.lowerBoundNanoseconds, 5)
        XCTAssertEqual(bounds?.upperBoundNanoseconds, 15)
    }

    func testRoundingMarginPreventsTinyFalseSleepAndSaturatesUpperBound() throws {
        let session = UUID()
        let rounded = RecoveryClockSample.provenSleepBounds(
            from: try sample(session, 100, 50, 101),
            to: try sample(session, 107, 55, 108),
            faultAt: 0,
            latestFaultAt: 100,
            restoredAt: 108,
            powerEvent: RecoveryPowerEventEvidence(bootSession: session, willSleepAtNanoseconds: 101, didWakeAtNanoseconds: 107)
        )
        XCTAssertEqual(rounded?.lowerBoundNanoseconds, 0)
        XCTAssertEqual(rounded?.upperBoundNanoseconds, 5)

        let maximum = RecoveryClockSample.provenSleepBounds(
            from: try sample(session, 0, 0, 0),
            to: try sample(session, UInt64.max - 1, 0, UInt64.max),
            faultAt: 0,
            latestFaultAt: 0,
            restoredAt: UInt64.max,
            powerEvent: RecoveryPowerEventEvidence(bootSession: session, willSleepAtNanoseconds: 0, didWakeAtNanoseconds: UInt64.max - 1)
        )
        XCTAssertEqual(maximum?.lowerBoundNanoseconds, UInt64.max - 3)
        XCTAssertEqual(maximum?.upperBoundNanoseconds, UInt64.max)
    }

    func testRejectsMissingMisplacedOrCrossBootPowerEvidence() throws {
        let session = UUID()
        let before = try sample(session, 4, 4, 4)
        let after = try sample(session, 20, 10, 20)
        let valid = RecoveryPowerEventEvidence(bootSession: session, willSleepAtNanoseconds: 5, didWakeAtNanoseconds: 15)

        XCTAssertNil(RecoverySuspensionEvidence(intervals: []).sleepBounds(bootSession: session, latestFaultAt: 1, restoredAt: 21))
        XCTAssertNil(RecoveryClockSample.provenSleepBounds(
            from: before, to: after, faultAt: 1, latestFaultAt: 1, restoredAt: 21,
            powerEvent: RecoveryPowerEventEvidence(bootSession: UUID(), willSleepAtNanoseconds: 5, didWakeAtNanoseconds: 15)
        ))
        XCTAssertNil(RecoveryClockSample.provenSleepBounds(
            from: before, to: after, faultAt: 1, latestFaultAt: 16, restoredAt: 21, powerEvent: valid
        ))
        XCTAssertNil(RecoveryClockSample.provenSleepBounds(
            from: after, to: before, faultAt: 1, latestFaultAt: 1, restoredAt: 21, powerEvent: valid
        ))
        XCTAssertThrowsError(try RecoveryClockSample(
            bootSession: session,
            continuousBeforeNanoseconds: 2,
            awakeNanoseconds: 1,
            continuousAfterNanoseconds: 0
        ))
        let invalidSample = Data(#"{"bootSession":"00000000-0000-0000-0000-000000000001","continuousBeforeNanoseconds":2,"awakeNanoseconds":1,"continuousAfterNanoseconds":0}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(RecoveryClockSample.self, from: invalidSample))
    }

    func testRejectsDuplicateAndOverlappingIntervals() throws {
        let session = UUID()
        let first = try interval(session, start: (1, 1, 1), end: (6, 3, 6), sleep: 2, wake: 5)
        let second = try interval(session, start: (8, 5, 8), end: (13, 6, 13), sleep: 9, wake: 12)

        let distinct = RecoverySuspensionEvidence(intervals: [first, second])
        XCTAssertEqual(distinct.sleepBounds(bootSession: session, latestFaultAt: 0, restoredAt: 14)?.lowerBoundNanoseconds, 3)
        XCTAssertEqual(distinct.sleepBounds(bootSession: session, latestFaultAt: 0, restoredAt: 14)?.upperBoundNanoseconds, 11)
        XCTAssertNil(RecoverySuspensionEvidence(intervals: [first, first]).sleepBounds(bootSession: session, latestFaultAt: 0, restoredAt: 14))

        let overlapping = try interval(session, start: (5, 2, 5), end: (10, 4, 10), sleep: 6, wake: 9)
        XCTAssertNil(RecoverySuspensionEvidence(intervals: [first, overlapping]).sleepBounds(bootSession: session, latestFaultAt: 0, restoredAt: 14))

        let otherBoot = try interval(UUID(), start: (15, 10, 15), end: (20, 11, 20), sleep: 16, wake: 19)
        XCTAssertNil(RecoverySuspensionEvidence(intervals: [first, otherBoot]).sleepBounds(bootSession: session, latestFaultAt: 0, restoredAt: 21))
    }

    private func sample(_ session: UUID, _ before: UInt64, _ awake: UInt64, _ after: UInt64) throws -> RecoveryClockSample {
        try RecoveryClockSample(
            bootSession: session,
            continuousBeforeNanoseconds: before,
            awakeNanoseconds: awake,
            continuousAfterNanoseconds: after
        )
    }

    private func interval(
        _ session: UUID,
        start: (UInt64, UInt64, UInt64),
        end: (UInt64, UInt64, UInt64),
        sleep: UInt64,
        wake: UInt64
    ) throws -> RecoverySuspensionInterval {
        RecoverySuspensionInterval(
            before: try sample(session, start.0, start.1, start.2),
            after: try sample(session, end.0, end.1, end.2),
            powerEvent: RecoveryPowerEventEvidence(bootSession: session, willSleepAtNanoseconds: sleep, didWakeAtNanoseconds: wake)
        )
    }
}
