import XCTest
@testable import ExtilumeNative

final class ConnectionCandidateStateTests: XCTestCase {
    func testUnidentifiableNegativeEventStaysInvalidAfterFirstMatch() {
        var state = ConnectionCandidateState()
        XCTAssertNil(state.invalidate(entryID: 0, terminated: true))
        XCTAssertTrue(state.invalidated)
        XCTAssertFalse(state.hasCandidates)

        XCTAssertTrue(state.matched(entryID: 42, service: .videoInterface, location: "External"))
        XCTAssertTrue(state.hasCandidates)
        XCTAssertTrue(state.invalidated)
    }

    func testEmptyOrUnknownObservationsCannotEstablishCandidatePresence() {
        var state = ConnectionCandidateState()
        XCTAssertFalse(state.hasCandidates)
        XCTAssertNil(state.invalidate(entryID: 9, terminated: true))
        XCTAssertTrue(state.invalidated)
        XCTAssertFalse(state.hasCandidates)
        XCTAssertFalse(state.matched(entryID: 0, service: .videoInterface, location: "External"))
        XCTAssertFalse(state.matched(entryID: 9, service: .videoInterface, location: nil))
        XCTAssertFalse(state.matched(entryID: 9, service: .videoInterface, location: "Unknown"))
        XCTAssertFalse(state.hasCandidates)
        XCTAssertTrue(state.matched(entryID: 9, service: .videoInterface, location: "External"))
        XCTAssertTrue(state.hasCandidates)
        XCTAssertTrue(state.invalidated)
        XCTAssertFalse(state.matched(entryID: 9, service: .videoInterface, location: "External"))
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

    func testMatchedTracksExternalCandidatesAndEmbeddedRoles() {
        var state = ConnectionCandidateState()

        XCTAssertFalse(state.matched(entryID: 0, service: .device, location: "External"))
        XCTAssertFalse(state.matched(entryID: 1, service: .device, location: nil))
        XCTAssertFalse(state.matched(entryID: 1, service: .device, location: "Unknown"))
        XCTAssertFalse(state.hasCandidates)

        XCTAssertTrue(state.matched(entryID: 1, service: .device, location: "External"))
        XCTAssertTrue(state.hasCandidates)
        XCTAssertFalse(state.matched(entryID: 1, service: .device, location: "External"))
        XCTAssertFalse(state.invalidated)
        XCTAssertTrue(state.matched(entryID: 2, service: .service, location: "Embedded"))
        XCTAssertTrue(state.isKnownEmbedded(entryID: 2))
        XCTAssertTrue(state.hasCandidates)
        XCTAssertFalse(state.matched(entryID: 2, service: .service, location: "Embedded"))
        XCTAssertFalse(state.invalidated)
        XCTAssertFalse(state.matched(entryID: 0, service: .service, location: "Embedded"))
        XCTAssertFalse(state.matched(entryID: 3, service: .service, location: nil))
        XCTAssertFalse(state.invalidated)
    }

    func testInitialMatchDoesNotInvalidate() {
        var state = ConnectionCandidateState()

        XCTAssertTrue(state.matched(entryID: 42, service: .service, location: "External"))
        XCTAssertFalse(state.invalidated)
    }

    func testKnownInterestAndTerminationInvalidateAndReturnService() {
        var state = ConnectionCandidateState()
        XCTAssertTrue(state.matched(entryID: 42, service: .videoInterface, location: "External"))

        XCTAssertEqual(state.invalidate(entryID: 42, terminated: false), .videoInterface)
        XCTAssertTrue(state.invalidated)
        XCTAssertEqual(state.invalidate(entryID: 42, terminated: true), .videoInterface)
        XCTAssertTrue(state.invalidated)
        XCTAssertNil(state.invalidate(entryID: 42, terminated: true))
    }

    func testUnknownInterestInvalidatesWithoutErasingTrackedCandidates() {
        var state = ConnectionCandidateState()
        XCTAssertTrue(state.matched(entryID: 7, service: .device, location: "External"))
        XCTAssertTrue(state.matched(entryID: 8, service: .service, location: "External"))
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
        XCTAssertTrue(state.matched(entryID: 42, service: .device, location: "External"))
        XCTAssertEqual(state.invalidate(entryID: 42, terminated: true), .device)
        XCTAssertFalse(state.hasCandidates)
        XCTAssertNil(state.invalidate(entryID: 42, terminated: true))
        XCTAssertTrue(state.invalidated)

        XCTAssertTrue(state.matched(entryID: 42, service: .service, location: "External"))
        XCTAssertTrue(state.hasCandidates)
        XCTAssertTrue(state.invalidated)
        XCTAssertFalse(state.matched(entryID: 42, service: .service, location: "External"))
        XCTAssertTrue(state.invalidated)
    }

    func testEmbeddedInvalidationRevokesRoleAndBlocksStaleLateMatchAndTermination() {
        var state = ConnectionCandidateState()
        XCTAssertTrue(state.matched(entryID: 70, service: .videoInterface, location: "Embedded"))
        XCTAssertTrue(state.isKnownEmbedded(entryID: 70))
        XCTAssertFalse(state.hasCandidates)

        XCTAssertNil(state.invalidate(entryID: 70, terminated: false))
        XCTAssertTrue(state.invalidated)
        XCTAssertFalse(state.isKnownEmbedded(entryID: 70))
        XCTAssertFalse(state.matched(entryID: 70, service: .videoInterface, location: "Embedded"))
        XCTAssertFalse(state.isKnownEmbedded(entryID: 70))
        XCTAssertFalse(state.consumeEmbeddedTermination(
            entryID: 70, service: .videoInterface, location: "Embedded"
        ))
        XCTAssertNil(state.invalidate(entryID: 70, terminated: true))
        XCTAssertTrue(state.invalidated)
        XCTAssertFalse(state.hasCandidates)
    }

    func testEmbeddedTerminationIsOneShotAndLateMatchCannotReauthorizeIt() {
        var state = ConnectionCandidateState()
        XCTAssertFalse(state.consumeEmbeddedTermination(entryID: 0, service: .device, location: "Embedded"))
        XCTAssertFalse(state.consumeEmbeddedTermination(entryID: 71, service: .device, location: "Embedded"))
        XCTAssertTrue(state.matched(entryID: 72, service: .device, location: "External"))
        XCTAssertFalse(state.consumeEmbeddedTermination(entryID: 72, service: .device, location: "External"))

        XCTAssertTrue(state.matched(entryID: 71, service: .device, location: "Embedded"))
        XCTAssertTrue(state.isKnownEmbedded(entryID: 71))
        XCTAssertFalse(state.consumeEmbeddedTermination(entryID: 71, service: .service, location: "Embedded"))
        XCTAssertTrue(state.consumeEmbeddedTermination(entryID: 71, service: .device, location: "Embedded"))
        // 保留已消费角色，用于识别迟到的冲突 matched。
        XCTAssertTrue(state.isKnownEmbedded(entryID: 71))
        XCTAssertFalse(state.invalidated)
        XCTAssertTrue(state.hasCandidates)

        XCTAssertFalse(state.consumeEmbeddedTermination(entryID: 71, service: .device, location: "Embedded"))
        XCTAssertFalse(state.matched(entryID: 71, service: .device, location: "Embedded"))
        XCTAssertTrue(state.isKnownEmbedded(entryID: 71))
        XCTAssertFalse(state.invalidated)
        XCTAssertFalse(state.matched(entryID: 71, service: .device, location: "External"))
        XCTAssertFalse(state.isKnownEmbedded(entryID: 71))
        XCTAssertFalse(state.matched(entryID: 71, service: .device, location: "Embedded"))
        XCTAssertFalse(state.consumeEmbeddedTermination(entryID: 71, service: .device, location: "Embedded"))
        XCTAssertTrue(state.invalidated)
        XCTAssertTrue(state.hasCandidates)
    }

    func testEmbeddedTerminationRequiresFreshEmbeddedLocationWithoutSpendingQuota() {
        var state = ConnectionCandidateState()
        XCTAssertTrue(state.matched(entryID: 73, service: .device, location: "Embedded"))

        XCTAssertFalse(state.consumeEmbeddedTermination(entryID: 73, service: .device, location: nil))
        XCTAssertFalse(state.consumeEmbeddedTermination(entryID: 73, service: .device, location: "External"))
        XCTAssertFalse(state.consumeEmbeddedTermination(entryID: 73, service: .device, location: "Unknown"))
        XCTAssertFalse(state.consumeEmbeddedTermination(entryID: 73, service: .device, location: "embedded"))
        XCTAssertTrue(state.isKnownEmbedded(entryID: 73))
        XCTAssertFalse(state.invalidated)

        XCTAssertTrue(state.consumeEmbeddedTermination(entryID: 73, service: .device, location: "Embedded"))
        XCTAssertTrue(state.isKnownEmbedded(entryID: 73))
        XCTAssertFalse(state.invalidated)
        XCTAssertFalse(state.hasCandidates)
    }

    func testClassAndLocationConflictsInvalidateAndRevokeEmbeddedExemption() {
        var externalThenEmbedded = ConnectionCandidateState()
        XCTAssertTrue(externalThenEmbedded.matched(entryID: 81, service: .device, location: "External"))
        XCTAssertFalse(externalThenEmbedded.matched(entryID: 81, service: .device, location: "Embedded"))
        XCTAssertTrue(externalThenEmbedded.invalidated)
        XCTAssertTrue(externalThenEmbedded.hasCandidates)
        XCTAssertFalse(externalThenEmbedded.isKnownEmbedded(entryID: 81))
        XCTAssertFalse(externalThenEmbedded.consumeEmbeddedTermination(
            entryID: 81, service: .device, location: "Embedded"
        ))

        var embeddedThenExternal = ConnectionCandidateState()
        XCTAssertTrue(embeddedThenExternal.matched(entryID: 82, service: .service, location: "Embedded"))
        XCTAssertFalse(embeddedThenExternal.matched(entryID: 82, service: .service, location: "External"))
        XCTAssertTrue(embeddedThenExternal.invalidated)
        XCTAssertFalse(embeddedThenExternal.hasCandidates)
        XCTAssertFalse(embeddedThenExternal.isKnownEmbedded(entryID: 82))
        XCTAssertFalse(embeddedThenExternal.matched(entryID: 82, service: .service, location: "Embedded"))
        XCTAssertFalse(embeddedThenExternal.consumeEmbeddedTermination(
            entryID: 82, service: .service, location: "External"
        ))

        var externalClassConflict = ConnectionCandidateState()
        XCTAssertTrue(externalClassConflict.matched(entryID: 83, service: .device, location: "External"))
        XCTAssertFalse(externalClassConflict.matched(entryID: 83, service: .service, location: "External"))
        XCTAssertTrue(externalClassConflict.invalidated)

        var embeddedClassConflict = ConnectionCandidateState()
        XCTAssertTrue(embeddedClassConflict.matched(entryID: 84, service: .device, location: "Embedded"))
        XCTAssertFalse(embeddedClassConflict.matched(entryID: 84, service: .service, location: "Embedded"))
        XCTAssertTrue(embeddedClassConflict.invalidated)
        XCTAssertFalse(embeddedClassConflict.isKnownEmbedded(entryID: 84))
        XCTAssertFalse(embeddedClassConflict.consumeEmbeddedTermination(
            entryID: 84, service: .device, location: "Embedded"
        ))
    }
}
