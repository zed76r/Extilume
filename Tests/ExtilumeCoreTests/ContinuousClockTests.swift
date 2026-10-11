import XCTest
@testable import ExtilumeCore

final class ContinuousClockTests: XCTestCase {
    func testConversionUsesFullWidthBeforeDivision() throws {
        XCTAssertEqual(try ContinuousClock.convert(ticks: UInt64.max, numerator: 2, denominator: 2), UInt64.max)
        XCTAssertEqual(try ContinuousClock.convert(ticks: 7, numerator: 3, denominator: 2), 10)
        XCTAssertEqual(try ContinuousClock.convert(ticks: 0, numerator: 1, denominator: 1), 0)
    }

    func testInvalidAndOverflowingTimebasesFail() {
        XCTAssertThrowsError(try ContinuousClock.convert(ticks: 1, numerator: 0, denominator: 1))
        XCTAssertThrowsError(try ContinuousClock.convert(ticks: 1, numerator: 1, denominator: 0))
        XCTAssertThrowsError(try ContinuousClock.convert(ticks: UInt64.max, numerator: 2, denominator: 1))
    }

    func testNativeClockDoesNotGoBackwards() throws {
        let before = try ContinuousClock.nanoseconds()
        XCTAssertGreaterThanOrEqual(try ContinuousClock.nanoseconds(), before)
    }
}
