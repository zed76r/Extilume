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
}
