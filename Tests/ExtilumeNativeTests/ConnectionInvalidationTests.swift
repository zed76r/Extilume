import CoreGraphics
import XCTest
@testable import ExtilumeNative

final class ConnectionInvalidationTests: XCTestCase {
    func testDisabledEventWithoutExpectedDisplayInvalidates() {
        XCTAssertEqual(connectionChangeInvalidationReason(
            display: 7,
            flags: .disabledFlag,
            expectedDisabledInternal: nil
        ), "cg-disabled")
    }

    func testExpectedInternalDisplayDisabledEventDoesNotInvalidate() {
        XCTAssertNil(connectionChangeInvalidationReason(
            display: 7,
            flags: .disabledFlag,
            expectedDisabledInternal: 7
        ))
    }

    func testOtherOrUnknownDisplayIDsDoNotReceiveTheExemption() {
        XCTAssertEqual(connectionChangeInvalidationReason(
            display: 8,
            flags: .disabledFlag,
            expectedDisabledInternal: 7
        ), "cg-disabled")
        XCTAssertEqual(connectionChangeInvalidationReason(
            display: 0,
            flags: .disabledFlag,
            expectedDisabledInternal: 7
        ), "cg-disabled")
        XCTAssertEqual(connectionChangeInvalidationReason(
            display: 7,
            flags: .disabledFlag,
            expectedDisabledInternal: 0
        ), "cg-disabled")
    }

    func testRemoveOnlyInvalidatesButExpectedDisabledRemoveCombinationsAreAllowed() {
        XCTAssertEqual(connectionChangeInvalidationReason(
            display: 7,
            flags: .removeFlag,
            expectedDisabledInternal: 7
        ), "cg-remove")
        XCTAssertNil(connectionChangeInvalidationReason(
            display: 7,
            flags: [.removeFlag, .disabledFlag],
            expectedDisabledInternal: 7
        ))
        XCTAssertNil(connectionChangeInvalidationReason(
            display: 7,
            flags: [.removeFlag, .disabledFlag, .desktopShapeChangedFlag],
            expectedDisabledInternal: 7
        ))
        XCTAssertEqual(connectionChangeInvalidationReason(
            display: 7,
            flags: [.removeFlag, .desktopShapeChangedFlag],
            expectedDisabledInternal: 7
        ), "cg-remove")
    }

    func testRemoveDisableExemptionRejectsAdditionalConflictingOrUnknownFlags() {
        let unknownFlag = CGDisplayChangeSummaryFlags(rawValue: 1 << 20)
        let removeDisabled = CGDisplayChangeSummaryFlags.removeFlag.union(.disabledFlag)
        let invalidCombinations: [CGDisplayChangeSummaryFlags] = [
            [.removeFlag, .disabledFlag, .enabledFlag],
            [.removeFlag, .disabledFlag, .desktopShapeChangedFlag, .enabledFlag],
            removeDisabled.union(unknownFlag)
        ]

        for flags in invalidCombinations {
            XCTAssertEqual(connectionChangeInvalidationReason(
                display: 7,
                flags: flags,
                expectedDisabledInternal: 7
            ), "cg-remove")
        }

        XCTAssertEqual(connectionChangeInvalidationReason(
            display: 7,
            flags: [.disabledFlag, .enabledFlag],
            expectedDisabledInternal: 7
        ), "cg-disabled")
        XCTAssertEqual(connectionChangeInvalidationReason(
            display: 7,
            flags: [.disabledFlag, .desktopShapeChangedFlag],
            expectedDisabledInternal: 7
        ), "cg-disabled")
    }

    func testObservedFlags4640ForExpectedInternalDisplayDoNotInvalidate() {
        XCTAssertNil(connectionChangeInvalidationReason(
            display: 7,
            flags: CGDisplayChangeSummaryFlags(rawValue: 4640),
            expectedDisabledInternal: 7
        ))
    }

    func testPositiveDisplayEventDoesNotInvalidate() {
        XCTAssertNil(connectionChangeInvalidationReason(
            display: 7,
            flags: .enabledFlag,
            expectedDisabledInternal: nil
        ))
    }
}
