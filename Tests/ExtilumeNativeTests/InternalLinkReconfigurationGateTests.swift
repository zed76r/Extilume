import CoreGraphics
import Foundation
import XCTest
@testable import ExtilumeNative

final class InternalLinkReconfigurationGateTests: XCTestCase {
    private let candidates: [UInt64: ExternalConnectionService] = [1: .device, 2: .service, 3: .videoInterface]

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 100
        func read() -> UInt64 { lock.withLock { value } }
        func set(_ value: UInt64) { lock.withLock { self.value = value } }
    }

    func testPreparedNotificationIsNegativeAndPreventsNativeInvocation() {
        let clock = Clock()
        let gate = InternalLinkReconfigurationGate(now: clock.read, onTimeout: { _ in XCTFail("unexpected timeout") })
        XCTAssertTrue(gate.prepare(candidates: candidates))
        XCTAssertFalse(gate.consume(entryID: 1, messageType: 0xe0115004, argument: .one, at: 101))
        XCTAssertEqual(gate.invalidate(observedAt: 101), 101)
        var calls = 0
        XCTAssertThrowsError(try gate.performNative { calls += 1; return .success })
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(gate.phase, .failed)
    }

    func testNativeReturnClosesWindowBeforeReadbackAndLaterMessageRevokes() throws {
        let clock = Clock()
        let gate = InternalLinkReconfigurationGate(now: clock.read, onTimeout: { _ in XCTFail("unexpected timeout") })
        XCTAssertTrue(gate.prepare(candidates: candidates))
        _ = try gate.performNative { .success }
        XCTAssertEqual(gate.phase, .verifying)
        XCTAssertFalse(gate.consume(entryID: 1, messageType: 0xe0115004, argument: .one, at: 101))
        XCTAssertEqual(gate.invalidate(observedAt: 101), 101)
        XCTAssertFalse(gate.verify(at: 102))
    }

    func testEarlierFaultIsNotOverwrittenByPendingAndUnknownClockRemainsUnknown() {
        for observed: UInt64? in [150, 250, nil] {
            let clock = Clock()
            let gate = InternalLinkReconfigurationGate(now: clock.read, onTimeout: { _ in XCTFail("unexpected timeout") })
            XCTAssertTrue(gate.prepare(candidates: candidates))
            XCTAssertThrowsError(try gate.performNative {
                clock.set(200)
                XCTAssertTrue(gate.consume(entryID: 1, messageType: 0xe0115004, argument: .one, at: 200))
                XCTAssertEqual(gate.invalidate(observedAt: observed), observed.map { min($0, 200) })
                clock.set(300)
                return .success
            })
        }
    }

    func testBudgetExpiresWhileNativeCallerIsBlockedAndRetainsFirstStopTime() {
        let clock = Clock()
        let expired = expectation(description: "independent budget callback")
        let gate = InternalLinkReconfigurationGate(now: clock.read) { first in
            XCTAssertEqual(first, 101)
            expired.fulfill()
        }
        XCTAssertTrue(gate.prepare(candidates: candidates))
        XCTAssertThrowsError(try gate.performNative {
            // Simulate an observed stop whose original budget has already elapsed in the queue.
            clock.set(10_000_000_101)
            XCTAssertTrue(gate.consume(entryID: 1, messageType: 0xe0115004, argument: .one, at: 101))
            wait(for: [expired], timeout: 1)
            XCTAssertEqual(gate.phase, .failed)
            return .success
        })
        XCTAssertEqual(gate.fail(), 101)
        XCTAssertFalse(gate.verify(at: 10_000_000_102))
    }
}
