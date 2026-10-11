import XCTest
@testable import ExtilumeCore

final class RecoveryTimingTests: XCTestCase {
    func testDeadlineIncludesExactlyTenSeconds() throws {
        let timing = try RecoveryTiming(
            faultAt: 100,
            notificationAt: 5_000_000_100,
            restoredAt: 10_000_000_100
        )

        XCTAssertEqual(timing.elapsedNanoseconds, 10_000_000_000)
        XCTAssertTrue(timing.withinDeadline)
    }

    func testDeadlineRejectsMoreThanTenSeconds() throws {
        let timing = try RecoveryTiming(faultAt: 100, notificationAt: 100, restoredAt: 10_000_000_101)

        XCTAssertEqual(timing.elapsedNanoseconds, 10_000_000_001)
        XCTAssertFalse(timing.withinDeadline)
    }

    func testNotificationDelayDoesNotRestartElapsedTime() throws {
        let timing = try RecoveryTiming(
            faultAt: 10,
            notificationAt: 9_000_000_010,
            restoredAt: 10_000_000_011
        )

        XCTAssertEqual(timing.elapsedNanoseconds, 10_000_000_001)
        XCTAssertFalse(timing.withinDeadline)
    }

    func testRejectsOutOfOrderUnsignedTimestamps() {
        XCTAssertThrowsError(try RecoveryTiming(faultAt: 2, notificationAt: 1, restoredAt: 2))
        XCTAssertThrowsError(try RecoveryTiming(faultAt: 1, notificationAt: 3, restoredAt: 2))
    }

    func testAcceptsEqualTimestampsAndLargeValuesWithoutOverflow() throws {
        let equal = try RecoveryTiming(faultAt: 5, notificationAt: 5, restoredAt: 5)
        XCTAssertEqual(equal.elapsedNanoseconds, 0)
        XCTAssertTrue(equal.withinDeadline)

        let restoredAt = UInt64.max
        let timing = try RecoveryTiming(
            faultAt: restoredAt - 10_000_000_000,
            notificationAt: restoredAt - 5_000_000_000,
            restoredAt: restoredAt
        )
        XCTAssertEqual(timing.elapsedNanoseconds, 10_000_000_000)
        XCTAssertTrue(timing.withinDeadline)
    }
}
