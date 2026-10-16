import XCTest
@testable import ExtilumeNative

final class ConnectionCandidateStateTests: XCTestCase {
    func testExternalServiceValues() {
        XCTAssertEqual(ExternalConnectionService.allCases.map(\.rawValue), [
            "DCPAVDeviceProxy",
            "DCPAVServiceProxy",
            "DCPAVVideoInterfaceProxy"
        ])
    }

    func testMatchedAcceptsOnlyExternalNonzeroUnseenEntries() {
        var state = ConnectionCandidateState()

        XCTAssertFalse(state.matched(entryID: 0, service: .device, isExternal: true))
        XCTAssertFalse(state.matched(entryID: 1, service: .device, isExternal: false))
        XCTAssertTrue(state.matched(entryID: 1, service: .device, isExternal: true))
        XCTAssertFalse(state.matched(entryID: 1, service: .service, isExternal: true))
        XCTAssertFalse(state.invalidated)
    }

    func testInitialMatchDoesNotInvalidate() {
        var state = ConnectionCandidateState()

        XCTAssertTrue(state.matched(entryID: 42, service: .service, isExternal: true))
        XCTAssertFalse(state.invalidated)
    }

    func testKnownInterestAndTerminationInvalidateAndReturnService() {
        var state = ConnectionCandidateState()
        XCTAssertTrue(state.matched(entryID: 42, service: .videoInterface, isExternal: true))

        XCTAssertEqual(state.invalidate(entryID: 42, terminated: false), .videoInterface)
        XCTAssertTrue(state.invalidated)
        XCTAssertEqual(state.invalidate(entryID: 42, terminated: true), .videoInterface)
        XCTAssertTrue(state.invalidated)
        XCTAssertNil(state.invalidate(entryID: 42, terminated: true))
    }

    func testUnknownEntryDoesNotInvalidate() {
        var state = ConnectionCandidateState()

        XCTAssertNil(state.invalidate(entryID: 7, terminated: false))
        XCTAssertNil(state.invalidate(entryID: 7, terminated: true))
        XCTAssertFalse(state.invalidated)
    }

    func testMatchAfterInvalidationDoesNotClearItIncludingReappearingEntry() {
        var state = ConnectionCandidateState()
        XCTAssertTrue(state.matched(entryID: 42, service: .device, isExternal: true))
        XCTAssertEqual(state.invalidate(entryID: 42, terminated: true), .device)

        XCTAssertTrue(state.matched(entryID: 42, service: .service, isExternal: true))
        XCTAssertTrue(state.invalidated)
        XCTAssertFalse(state.matched(entryID: 42, service: .service, isExternal: true))
        XCTAssertTrue(state.invalidated)
    }
}
