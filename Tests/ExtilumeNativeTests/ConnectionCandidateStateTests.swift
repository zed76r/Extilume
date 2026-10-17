import XCTest
@testable import ExtilumeNative

final class ConnectionCandidateStateTests: XCTestCase {
    func testUnidentifiableNegativeEventStaysInvalidAfterFirstMatch() {
        var state = ConnectionCandidateState()
        XCTAssertNil(state.invalidate(entryID: 0, terminated: true))
        XCTAssertTrue(state.invalidated)
        XCTAssertFalse(state.hasCandidates)

        XCTAssertTrue(state.matched(entryID: 42, service: .videoInterface, isExternal: true))
        XCTAssertTrue(state.hasCandidates)
        XCTAssertTrue(state.invalidated)
    }

    func testEmptyOrUnknownObservationsCannotEstablishCandidatePresence() {
        var state = ConnectionCandidateState()
        XCTAssertFalse(state.hasCandidates)
        XCTAssertNil(state.invalidate(entryID: 9, terminated: true))
        XCTAssertTrue(state.invalidated)
        XCTAssertFalse(state.hasCandidates)
        XCTAssertFalse(state.matched(entryID: 0, service: .videoInterface, isExternal: true))
        XCTAssertFalse(state.matched(entryID: 9, service: .videoInterface, isExternal: false))
        XCTAssertFalse(state.hasCandidates)
        XCTAssertTrue(state.matched(entryID: 9, service: .videoInterface, isExternal: true))
        XCTAssertTrue(state.hasCandidates)
        XCTAssertTrue(state.invalidated)
        XCTAssertEqual(state.invalidate(entryID: 9, terminated: false), .videoInterface)
        XCTAssertTrue(state.hasCandidates)
        XCTAssertEqual(state.invalidate(entryID: 9, terminated: true), .videoInterface)
        XCTAssertFalse(state.hasCandidates)
        XCTAssertTrue(state.invalidated)
    }

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

    func testUnknownInterestInvalidatesWithoutErasingTrackedCandidates() {
        var state = ConnectionCandidateState()
        XCTAssertTrue(state.matched(entryID: 7, service: .device, isExternal: true))
        XCTAssertTrue(state.matched(entryID: 8, service: .service, isExternal: true))
        XCTAssertTrue(state.hasCandidates)

        XCTAssertNil(state.invalidate(entryID: 9, terminated: false))
        XCTAssertTrue(state.invalidated)
        XCTAssertTrue(state.hasCandidates)
        XCTAssertEqual(state.invalidate(entryID: 7, terminated: false), .device)
        XCTAssertEqual(state.invalidate(entryID: 8, terminated: false), .service)
        XCTAssertTrue(state.hasCandidates)
    }

    func testMatchAfterInvalidationDoesNotClearItIncludingReappearingEntry() {
        var state = ConnectionCandidateState()
        XCTAssertTrue(state.matched(entryID: 42, service: .device, isExternal: true))
        XCTAssertEqual(state.invalidate(entryID: 42, terminated: true), .device)
        XCTAssertFalse(state.hasCandidates)
        XCTAssertNil(state.invalidate(entryID: 42, terminated: true))
        XCTAssertTrue(state.invalidated)

        XCTAssertTrue(state.matched(entryID: 42, service: .service, isExternal: true))
        XCTAssertTrue(state.hasCandidates)
        XCTAssertTrue(state.invalidated)
        XCTAssertFalse(state.matched(entryID: 42, service: .service, isExternal: true))
        XCTAssertTrue(state.invalidated)
    }
}
