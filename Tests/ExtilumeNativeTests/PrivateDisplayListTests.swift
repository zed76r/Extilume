import XCTest
@testable import ExtilumeNative

final class PrivateDisplayListTests: XCTestCase {
    func testValidPrefixPreservesOrderAndIgnoresTail() {
        XCTAssertEqual(validatedPrivateDisplayIDs(storage: [42, 7, 0, 99], count: 2, status: 0), [42, 7])
    }

    func testEmptyResult() {
        XCTAssertEqual(validatedPrivateDisplayIDs(storage: [0, 0], count: 0, status: 0), [])
    }

    func testRejectsNativeError() {
        XCTAssertNil(validatedPrivateDisplayIDs(storage: [42, 0], count: 1, status: 1))
    }

    func testRejectsCountAtOrBeyondCapacity() {
        XCTAssertNil(validatedPrivateDisplayIDs(storage: [42, 7], count: 2, status: 0))
        XCTAssertNil(validatedPrivateDisplayIDs(storage: [42, 7], count: 3, status: 0))
    }

    func testRejectsZeroInValidPrefix() {
        XCTAssertNil(validatedPrivateDisplayIDs(storage: [42, 0, 7], count: 2, status: 0))
    }
}
