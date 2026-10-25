import XCTest
@testable import ExtilumeCore

final class RecoveryTimingTests: XCTestCase {
    func testPointTimingKeepsExistingBehaviorAndCountsNotificationDelay() throws {
        let exactDeadline = try RecoveryTiming(
            faultAt: 100,
            notificationAt: 5_000_000_100,
            restoredAt: 10_000_000_100
        )

        XCTAssertEqual(exactDeadline.latestFaultAt, exactDeadline.faultAt)
        XCTAssertEqual(exactDeadline.uncertaintyNanoseconds, 0)
        XCTAssertEqual(exactDeadline.elapsedNanoseconds, 10_000_000_000)
        XCTAssertEqual(exactDeadline.minimumElapsedNanoseconds, 10_000_000_000)
        XCTAssertTrue(exactDeadline.withinDeadline)
        XCTAssertEqual(exactDeadline.assessment, .withinDeadline)

        let equal = try RecoveryTiming(faultAt: 5, notificationAt: 5, restoredAt: 5)
        XCTAssertEqual(equal.elapsedNanoseconds, 0)
        XCTAssertEqual(equal.minimumElapsedNanoseconds, 0)
        XCTAssertTrue(equal.withinDeadline)

        let maximumTimestamp = UInt64.max
        let largeValues = try RecoveryTiming(
            faultAt: maximumTimestamp - 10_000_000_000,
            notificationAt: maximumTimestamp - 5_000_000_000,
            restoredAt: maximumTimestamp
        )
        XCTAssertEqual(largeValues.elapsedNanoseconds, 10_000_000_000)
        XCTAssertTrue(largeValues.withinDeadline)

        let delayedNotification = try RecoveryTiming(
            faultAt: 10,
            notificationAt: 9_000_000_010,
            restoredAt: 10_000_000_011
        )

        XCTAssertEqual(delayedNotification.elapsedNanoseconds, 10_000_000_001)
        XCTAssertFalse(delayedNotification.withinDeadline)
        XCTAssertEqual(delayedNotification.assessment, .exceeded)
    }

    func testIntervalAssessmentUsesBothElapsedBounds() throws {
        let within = try RecoveryTiming(
            faultAt: 100,
            latestFaultAt: 1_000_000_100,
            notificationAt: 5_000_000_100,
            restoredAt: 10_000_000_100
        )
        XCTAssertEqual(within.elapsedNanoseconds, 10_000_000_000)
        XCTAssertEqual(within.minimumElapsedNanoseconds, 9_000_000_000)
        XCTAssertEqual(within.assessment, .withinDeadline)

        let exceeded = try RecoveryTiming(
            faultAt: 100,
            latestFaultAt: 1_000_000_100,
            notificationAt: 9_000_000_100,
            restoredAt: 11_000_000_101
        )
        XCTAssertEqual(exceeded.minimumElapsedNanoseconds, 10_000_000_001)
        XCTAssertEqual(exceeded.assessment, .exceeded)

        let crossing = try RecoveryTiming(
            faultAt: 100,
            latestFaultAt: 2_000_000_100,
            notificationAt: 1_000_000_100,
            restoredAt: 10_000_000_101
        )
        XCTAssertEqual(crossing.elapsedNanoseconds, 10_000_000_001)
        XCTAssertEqual(crossing.minimumElapsedNanoseconds, 8_000_000_001)
        XCTAssertEqual(crossing.assessment, .inconclusive)

        let lowerBoundAtDeadline = try RecoveryTiming(
            faultAt: 100,
            latestFaultAt: 1_000_000_100,
            notificationAt: 9_000_000_100,
            restoredAt: 11_000_000_100
        )
        XCTAssertEqual(lowerBoundAtDeadline.minimumElapsedNanoseconds, 10_000_000_000)
        XCTAssertEqual(lowerBoundAtDeadline.elapsedNanoseconds, 11_000_000_000)
        XCTAssertEqual(lowerBoundAtDeadline.assessment, .inconclusive)
    }

    func testLatestFaultCanFollowNotificationOrRestorationWithoutTruncation() throws {
        let afterNotification = try RecoveryTiming(
            faultAt: 100,
            latestFaultAt: 9_000_000_101,
            notificationAt: 9_000_000_100,
            restoredAt: 10_000_000_100
        )
        XCTAssertEqual(afterNotification.uncertaintyNanoseconds, 9_000_000_001)
        XCTAssertEqual(afterNotification.minimumElapsedNanoseconds, 999_999_999)

        let restoredAt = UInt64.max - 1
        let afterRestoration = try RecoveryTiming(
            faultAt: restoredAt - 10_000_000_000,
            latestFaultAt: UInt64.max,
            notificationAt: restoredAt - 5_000_000_000,
            restoredAt: restoredAt
        )
        XCTAssertEqual(afterRestoration.uncertaintyNanoseconds, 10_000_000_001)
        XCTAssertEqual(afterRestoration.elapsedNanoseconds, 10_000_000_000)
        XCTAssertEqual(afterRestoration.minimumElapsedNanoseconds, 0)
        XCTAssertEqual(afterRestoration.assessment, .withinDeadline)
    }

    func testRejectsInvalidTimestampAndFaultWindowOrder() {
        XCTAssertThrowsError(try RecoveryTiming(faultAt: 2, latestFaultAt: 1, notificationAt: 2, restoredAt: 2))
        XCTAssertThrowsError(try RecoveryTiming(faultAt: 2, notificationAt: 1, restoredAt: 2))
        XCTAssertThrowsError(try RecoveryTiming(faultAt: 1, notificationAt: 3, restoredAt: 2))
    }

    func testVerifiedSleepSeparatesContinuousAndAwakeBounds() throws {
        let session = UUID()
        let evidence = RecoverySuspensionEvidence(intervals: [
            RecoverySuspensionInterval(
                before: try sample(session, 2_000_000_000, 2_000_000_000, 4_000_000_000),
                after: try sample(session, 20_000_000_000, 4_000_000_000, 22_000_000_000),
                powerEvent: RecoveryPowerEventEvidence(
                    bootSession: session,
                    willSleepAtNanoseconds: 4_000_000_000,
                    didWakeAtNanoseconds: 18_000_000_000
                )
            )
        ])
        let timing = try RecoveryTiming(
            faultAt: 0,
            latestFaultAt: 1_000_000_000,
            notificationAt: 3_000_000_000,
            restoredAt: 22_000_000_000,
            suspensionEvidence: evidence,
            clockContext: RecoveryTimingClockContext(
                faultBefore: try sample(session, 0, 0, 0),
                faultAfter: try sample(session, 1_000_000_000, 1_000_000_000, 1_000_000_000),
                notification: try sample(session, 3_000_000_000, 3_000_000_000, 3_000_000_000),
                restored: try sample(session, 22_000_000_000, 4_000_000_000, 22_000_000_000)
            )
        )

        XCTAssertEqual(timing.elapsedNanoseconds, 22_000_000_000)
        XCTAssertEqual(timing.minimumElapsedNanoseconds, 21_000_000_000)
        XCTAssertEqual(timing.suspensionBounds?.lowerBoundNanoseconds, 13_999_999_998)
        XCTAssertEqual(timing.suspensionBounds?.upperBoundNanoseconds, 18_000_000_002)
        XCTAssertEqual(timing.awakeElapsedNanoseconds, 8_000_000_002)
        XCTAssertEqual(timing.minimumAwakeElapsedNanoseconds, 2_999_999_998)
        XCTAssertEqual(timing.assessment, .exceeded)
        XCTAssertEqual(timing.awakeAssessment, .withinDeadline)
    }

    func testMissingSleepEvidenceKeepsLegacyTimingConclusion() throws {
        let timing = try RecoveryTiming(
            faultAt: 0,
            notificationAt: 9_000_000_000,
            restoredAt: 11_000_000_001,
            suspensionEvidence: RecoverySuspensionEvidence(intervals: [])
        )

        XCTAssertNil(timing.suspensionBounds)
        XCTAssertEqual(timing.elapsedNanoseconds, 11_000_000_001)
        XCTAssertEqual(timing.awakeElapsedNanoseconds, timing.elapsedNanoseconds)
        XCTAssertEqual(timing.assessment, .exceeded)
        XCTAssertEqual(timing.awakeAssessment, .exceeded)
    }

    func testOrderedNumbersFromDifferentBootsCannotProveAwakeDeadline() throws {
        let unit: UInt64 = 1_000_000_000
        let firstBoot = UUID(), secondBoot = UUID()
        let context = RecoveryTimingClockContext(
            faultBefore: try sample(firstBoot, 100 * unit, 100 * unit, 100 * unit),
            faultAfter: try sample(secondBoot, 100 * unit, 100 * unit, 100 * unit),
            notification: try sample(secondBoot, 101 * unit, 101 * unit, 101 * unit),
            restored: try sample(secondBoot, 122 * unit, 102 * unit, 122 * unit)
        )
        XCTAssertThrowsError(try RecoveryTiming(clockContext: context)) {
            XCTAssertEqual($0 as? RecoveryTimingError, .incomparableClock)
        }
        let evidence = RecoverySuspensionEvidence(intervals: [RecoverySuspensionInterval(
            before: try sample(secondBoot, 101 * unit, 101 * unit, 101 * unit),
            after: try sample(secondBoot, 121 * unit, 102 * unit, 121 * unit),
            powerEvent: RecoveryPowerEventEvidence(bootSession: secondBoot, willSleepAtNanoseconds: 101 * unit, didWakeAtNanoseconds: 121 * unit)
        )])
        let raw = try RecoveryTiming(faultAt: 100 * unit, notificationAt: 101 * unit, restoredAt: 122 * unit, suspensionEvidence: evidence)
        XCTAssertNil(raw.suspensionBounds)
        XCTAssertEqual(raw.awakeElapsedNanoseconds, 22 * unit)
        XCTAssertEqual(raw.awakeAssessment, .exceeded)
        XCTAssertNil(evidence.sleepBounds(bootSession: firstBoot, latestFaultAt: 100 * unit, restoredAt: 122 * unit))
    }

    private func sample(_ session: UUID, _ before: UInt64, _ awake: UInt64, _ after: UInt64) throws -> RecoveryClockSample {
        try RecoveryClockSample(
            bootSession: session,
            continuousBeforeNanoseconds: before,
            awakeNanoseconds: awake,
            continuousAfterNanoseconds: after
        )
    }
}
