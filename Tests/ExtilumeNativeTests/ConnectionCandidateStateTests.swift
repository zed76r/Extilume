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

    func testDiagnosticCandidateReportsUnidentifiedUnregisteredAndRegisteredRoles() {
        var state = ConnectionCandidateState()

        XCTAssertEqual(
            state.diagnosticCandidate(entryID: 0),
            ConnectionCandidateDiagnostic(role: .unidentified, service: nil)
        )
        XCTAssertEqual(
            state.diagnosticCandidate(entryID: 1),
            ConnectionCandidateDiagnostic(role: .unregistered, service: nil)
        )

        XCTAssertTrue(state.matched(entryID: 2, service: .device, location: "External"))
        let external = ConnectionCandidateDiagnostic(role: .registeredExternal, service: .device)
        XCTAssertEqual(state.diagnosticCandidate(entryID: 2), external)
        XCTAssertEqual(state.diagnosticCandidate(entryID: 2), external)
        XCTAssertFalse(state.matched(entryID: 2, service: .device, location: "External"))
        XCTAssertFalse(state.invalidated)
        XCTAssertTrue(state.hasCandidates)

        XCTAssertTrue(state.matched(entryID: 3, service: .service, location: "Embedded"))
        let embedded = ConnectionCandidateDiagnostic(role: .registeredEmbedded, service: .service)
        XCTAssertEqual(state.diagnosticCandidate(entryID: 3), embedded)
        XCTAssertEqual(state.diagnosticCandidate(entryID: 3), embedded)
        XCTAssertTrue(state.isKnownEmbedded(entryID: 3))
        XCTAssertFalse(state.invalidated)
        XCTAssertTrue(state.hasCandidates)
    }

    func testDiagnosticCandidateDoesNotChangeEmbeddedQuotaOrRevocationEffects() {
        var consumed = ConnectionCandidateState()
        XCTAssertTrue(consumed.matched(entryID: 40, service: .device, location: "Embedded"))
        let embedded = ConnectionCandidateDiagnostic(role: .registeredEmbedded, service: .device)
        XCTAssertEqual(consumed.diagnosticCandidate(entryID: 40), embedded)
        XCTAssertEqual(consumed.diagnosticCandidate(entryID: 40), embedded)
        XCTAssertTrue(consumed.consumeEmbeddedTermination(
            entryID: 40, service: .device, location: "Embedded"
        ))

        let retiredWithService = ConnectionCandidateDiagnostic(role: .retiredEmbedded, service: .device)
        XCTAssertEqual(consumed.diagnosticCandidate(entryID: 40), retiredWithService)
        XCTAssertEqual(consumed.diagnosticCandidate(entryID: 40), retiredWithService)
        XCTAssertTrue(consumed.isKnownEmbedded(entryID: 40))
        XCTAssertFalse(consumed.hasCandidates)
        XCTAssertFalse(consumed.invalidated)
        XCTAssertFalse(consumed.consumeEmbeddedTermination(
            entryID: 40, service: .device, location: "Embedded"
        ))

        XCTAssertFalse(consumed.matched(entryID: 40, service: .device, location: "External"))
        XCTAssertTrue(consumed.invalidated)
        XCTAssertFalse(consumed.isKnownEmbedded(entryID: 40))
        XCTAssertEqual(consumed.diagnosticCandidate(entryID: 40), .init(role: .retiredEmbedded, service: nil))
        XCTAssertFalse(consumed.matched(entryID: 40, service: .device, location: "Embedded"))
        XCTAssertFalse(consumed.consumeEmbeddedTermination(
            entryID: 40, service: .device, location: "Embedded"
        ))

        var revoked = ConnectionCandidateState()
        XCTAssertTrue(revoked.matched(entryID: 41, service: .service, location: "Embedded"))
        XCTAssertNil(revoked.invalidate(entryID: 41, terminated: false))
        let retiredWithoutService = ConnectionCandidateDiagnostic(role: .retiredEmbedded, service: nil)
        XCTAssertEqual(revoked.diagnosticCandidate(entryID: 41), retiredWithoutService)
        XCTAssertEqual(revoked.diagnosticCandidate(entryID: 41), retiredWithoutService)
        XCTAssertFalse(revoked.isKnownEmbedded(entryID: 41))
        XCTAssertFalse(revoked.matched(entryID: 41, service: .service, location: "Embedded"))
        XCTAssertFalse(revoked.consumeEmbeddedTermination(
            entryID: 41, service: .service, location: "Embedded"
        ))
        XCTAssertTrue(revoked.invalidated)
        XCTAssertFalse(revoked.hasCandidates)

        var terminated = ConnectionCandidateState()
        XCTAssertTrue(terminated.matched(entryID: 42, service: .videoInterface, location: "External"))
        XCTAssertEqual(terminated.invalidate(entryID: 42, terminated: true), .videoInterface)
        let unregistered = ConnectionCandidateDiagnostic(role: .unregistered, service: nil)
        XCTAssertEqual(terminated.diagnosticCandidate(entryID: 42), unregistered)
        XCTAssertEqual(terminated.diagnosticCandidate(entryID: 42), unregistered)
        XCTAssertNil(terminated.invalidate(entryID: 42, terminated: true))
        XCTAssertTrue(terminated.invalidated)
        XCTAssertFalse(terminated.hasCandidates)
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

    func testProtectionInformationAllowsEachExternalServiceAndLegalArgumentWithoutMutation() {
        let arguments: [ConnectionObservedArgument] = [.zero, .one, .two]

        for service in ExternalConnectionService.allCases {
            let state = externalState(entryID: 7_100_101, service: service)
            let candidateBefore = state.diagnosticCandidate(entryID: 7_100_101)

            for argument in arguments {
                XCTAssertTrue(protectionAllowed(state, entryID: 7_100_101, argument: argument),
                              "\(service.rawValue), \(argument.rawValue)")
            }

            XCTAssertEqual(state.diagnosticCandidate(entryID: 7_100_101), candidateBefore)
            XCTAssertTrue(state.hasCandidates)
            XCTAssertFalse(state.invalidated)
        }
    }

    func testProtectionInformationRequiresPositiveEntryIDInternalDisplayAndRegisteredInterest() {
        let state = externalState(entryID: 7_100_102, service: .device)

        XCTAssertFalse(protectionAllowed(state, entryID: 0))
        for internalDisplayID: UInt32? in [nil, 0] {
            XCTAssertFalse(protectionAllowed(state, entryID: 7_100_102,
                                             internalDisplayID: internalDisplayID))
        }
        XCTAssertFalse(protectionAllowed(state, entryID: 7_100_102, interestRegistered: false))
        XCTAssertTrue(state.hasCandidates)
        XCTAssertFalse(state.invalidated)
    }

    func testProtectionInformationRejectsUnknownEmbeddedRetiredConflictingAndInvalidatedRoles() {
        let unknown = ConnectionCandidateState()
        XCTAssertFalse(protectionAllowed(unknown, entryID: 7_100_103))

        var embedded = ConnectionCandidateState()
        XCTAssertTrue(embedded.matched(entryID: 7_100_104, service: .service, location: "Embedded"))
        XCTAssertFalse(protectionAllowed(embedded, entryID: 7_100_104))

        var retired = ConnectionCandidateState()
        XCTAssertTrue(retired.matched(entryID: 7_100_105, service: .device, location: "Embedded"))
        XCTAssertTrue(retired.consumeEmbeddedTermination(
            entryID: 7_100_105, service: .device, location: "Embedded"
        ))
        XCTAssertFalse(protectionAllowed(retired, entryID: 7_100_105))

        var classConflict = externalState(entryID: 7_100_106, service: .device)
        XCTAssertFalse(classConflict.matched(
            entryID: 7_100_106, service: .service, location: "External"
        ))
        XCTAssertTrue(classConflict.invalidated)
        XCTAssertFalse(protectionAllowed(classConflict, entryID: 7_100_106))

        var locationConflict = externalState(entryID: 7_100_107, service: .videoInterface)
        XCTAssertFalse(locationConflict.matched(
            entryID: 7_100_107, service: .videoInterface, location: "Embedded"
        ))
        XCTAssertTrue(locationConflict.invalidated)
        XCTAssertFalse(protectionAllowed(locationConflict, entryID: 7_100_107))

        var invalidated = externalState(entryID: 7_100_108, service: .service)
        XCTAssertEqual(invalidated.invalidate(entryID: 7_100_108, terminated: false), .service)
        XCTAssertFalse(protectionAllowed(invalidated, entryID: 7_100_108))
    }

    func testProtectionInformationRejectsUnknownCodesAndAllLinkMessages() {
        let state = externalState(entryID: 7_100_109, service: .videoInterface)
        let linkMessages: [UInt32] = [0xe0115000, 0xe0115001, 0xe0115004, 0xe0115005]
        let arguments: [ConnectionObservedArgument] = [.zero, .one, .two, .other]

        for messageType in linkMessages {
            for argument in arguments {
                XCTAssertFalse(protectionAllowed(state, entryID: 7_100_109,
                                                 messageType: messageType, argument: argument),
                               String(format: "0x%08x %@", messageType, argument.rawValue))
            }
        }
        XCTAssertFalse(protectionAllowed(state, entryID: 7_100_109, messageType: 0xdeadbeef))
        XCTAssertFalse(protectionAllowed(state, entryID: 7_100_109, argument: .other))
    }

    func testProtectionInformationCannotRestoreOrPreventNegativeInvalidation() {
        var invalidated = externalState(entryID: 7_100_110, service: .device)
        XCTAssertEqual(invalidated.invalidate(entryID: 7_100_110, terminated: false), .device)
        XCTAssertTrue(invalidated.invalidated)
        XCTAssertFalse(protectionAllowed(invalidated, entryID: 7_100_110))
        XCTAssertFalse(invalidated.matched(entryID: 7_100_110, service: .device, location: "External"))
        XCTAssertFalse(protectionAllowed(invalidated, entryID: 7_100_110))
        XCTAssertTrue(invalidated.invalidated)

        var protectedFirst = externalState(entryID: 7_100_111, service: .service)
        XCTAssertTrue(protectionAllowed(protectedFirst, entryID: 7_100_111))
        XCTAssertEqual(protectedFirst.invalidate(entryID: 7_100_111, terminated: false), .service)
        XCTAssertTrue(protectedFirst.invalidated)
        XCTAssertFalse(protectionAllowed(protectedFirst, entryID: 7_100_111))
        XCTAssertFalse(protectedFirst.matched(
            entryID: 7_100_111, service: .service, location: "External"
        ))
        XCTAssertTrue(protectedFirst.invalidated)
    }

    func testReconfigurationCandidatesRequireAllThreeRegisteredExternalServices() {
        let expected: [UInt64: ExternalConnectionService] = [
            7_200_101: .device, 7_200_102: .service, 7_200_103: .videoInterface,
        ]
        var state = ConnectionCandidateState()
        for (entryID, service) in expected {
            XCTAssertTrue(state.matched(entryID: entryID, service: service, location: "External"))
        }

        XCTAssertEqual(
            state.reconfigurationCandidates(registered: Set(expected.keys), internalDisplayID: 17),
            expected
        )
        XCTAssertNil(state.reconfigurationCandidates(
            registered: Set(expected.keys.dropLast()), internalDisplayID: 17
        ))
        XCTAssertNil(state.reconfigurationCandidates(registered: Set(expected.keys), internalDisplayID: nil))
        XCTAssertNil(state.reconfigurationCandidates(registered: Set(expected.keys), internalDisplayID: 0))
    }

    func testReconfigurationCandidatesRejectDuplicateOrAdditionalExternalServices() {
        var duplicateClass = ConnectionCandidateState()
        XCTAssertTrue(duplicateClass.matched(entryID: 7_200_111, service: .device, location: "External"))
        XCTAssertTrue(duplicateClass.matched(entryID: 7_200_112, service: .device, location: "External"))
        XCTAssertTrue(duplicateClass.matched(entryID: 7_200_113, service: .service, location: "External"))
        XCTAssertNil(duplicateClass.reconfigurationCandidates(
            registered: [7_200_111, 7_200_112, 7_200_113], internalDisplayID: 17
        ))

        var additional = ConnectionCandidateState()
        XCTAssertTrue(additional.matched(entryID: 7_200_121, service: .device, location: "External"))
        XCTAssertTrue(additional.matched(entryID: 7_200_122, service: .service, location: "External"))
        XCTAssertTrue(additional.matched(entryID: 7_200_123, service: .videoInterface, location: "External"))
        XCTAssertTrue(additional.matched(entryID: 7_200_124, service: .device, location: "External"))
        XCTAssertNil(additional.reconfigurationCandidates(
            registered: [7_200_121, 7_200_122, 7_200_123, 7_200_124], internalDisplayID: 17
        ))
    }

    func testReconfigurationCandidatesRejectInvalidationAndRoleConflict() {
        var invalidated = externalSetForReconfiguration()
        XCTAssertEqual(invalidated.invalidate(entryID: 7_200_131, terminated: false), .device)
        XCTAssertNil(invalidated.reconfigurationCandidates(
            registered: [7_200_131, 7_200_132, 7_200_133], internalDisplayID: 17
        ))

        var conflicted = externalSetForReconfiguration()
        XCTAssertFalse(conflicted.matched(entryID: 7_200_131, service: .service, location: "External"))
        XCTAssertTrue(conflicted.invalidated)
        XCTAssertNil(conflicted.reconfigurationCandidates(
            registered: [7_200_131, 7_200_132, 7_200_133], internalDisplayID: 17
        ))
    }

    func testEmbeddedRegistrationDoesNotJoinReconfigurationCandidates() {
        var state = ConnectionCandidateState()
        XCTAssertTrue(state.matched(entryID: 7_200_140, service: .service, location: "Embedded"))
        let expected: [UInt64: ExternalConnectionService] = [
            7_200_141: .device, 7_200_142: .service, 7_200_143: .videoInterface,
        ]
        for (entryID, service) in expected {
            XCTAssertTrue(state.matched(entryID: entryID, service: service, location: "External"))
        }

        let qualified = state.reconfigurationCandidates(registered: Set(expected.keys), internalDisplayID: 17)
        XCTAssertEqual(qualified, expected)
        XCTAssertNil(qualified?[7_200_140])
    }

    private func externalState(
        entryID: UInt64,
        service: ExternalConnectionService
    ) -> ConnectionCandidateState {
        var state = ConnectionCandidateState()
        XCTAssertTrue(state.matched(entryID: entryID, service: service, location: "External"))
        return state
    }

    private func externalSetForReconfiguration() -> ConnectionCandidateState {
        var state = ConnectionCandidateState()
        XCTAssertTrue(state.matched(entryID: 7_200_131, service: .device, location: "External"))
        XCTAssertTrue(state.matched(entryID: 7_200_132, service: .service, location: "External"))
        XCTAssertTrue(state.matched(entryID: 7_200_133, service: .videoInterface, location: "External"))
        return state
    }

    private func protectionAllowed(
        _ state: ConnectionCandidateState,
        entryID: UInt64,
        messageType: UInt32 = 0xe0115006,
        argument: ConnectionObservedArgument = .zero,
        interestRegistered: Bool = true,
        internalDisplayID: UInt32? = 17
    ) -> Bool {
        state.permitsProtectionInformation(
            entryID: entryID,
            messageType: messageType,
            messageArgument: argument,
            interestRegistered: interestRegistered,
            internalDisplayID: internalDisplayID
        )
    }
}
