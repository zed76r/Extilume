import CoreGraphics
import Foundation
import XCTest
@testable import ExtilumeNative

final class ConnectionObservationTests: XCTestCase {
    func testProtectionParameterTwoIsDistinctFromUnknownAndNotALinkType() {
        XCTAssertEqual(ConnectionObservedArgument(UnsafeMutableRawPointer(bitPattern: 2)), .two)
        XCTAssertEqual(ConnectionObservedArgument(UnsafeMutableRawPointer(bitPattern: 3)), .other)
        let candidate = ConnectionCandidateDiagnostic(role: .registeredExternal, service: .device)
        XCTAssertEqual(connectionMessageClassification(event: .interest, candidate: candidate,
            messageType: 0xe0115006, messageArgument: .two), .protectionChanged)
        for code: UInt32 in [0xe0115000, 0xe0115001, 0xe0115004, 0xe0115005] {
            XCTAssertEqual(connectionMessageClassification(event: .interest, candidate: candidate,
                messageType: code, messageArgument: .two), .unknown)
        }
    }

    func testInformationMarkerDoesNotClaimRevocationOrExposeIdentity() throws {
        let marker = ConnectionObservation(role: .controller, observerStartedAtNanoseconds: 100,
            continuousNs: 124, event: .interest, candidateOrdinal: 1,
            candidate: ConnectionCandidateDiagnostic(role: .registeredExternal, service: .service),
            registryScope: .other, messageType: 0xe0115006, messageArgument: .two,
            messageClassification: .protectionChanged, observedLocation: nil, initial: nil,
            disposition: .informational, invalidated: false)
        let line = try connectionObservationMarker(marker)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(value["disposition"] as? String, "informational")
        XCTAssertEqual(value["messageArgument"] as? String, "two")
        XCTAssertEqual(value["invalidated"] as? Bool, false)
        XCTAssertFalse(line.contains("entryID"))
    }

    private func observation(
        event: ConnectionObservationEvent = .terminated,
        messageClassification: ConnectionMessageClassification? = nil
    ) -> ConnectionObservation {
        var state = ConnectionCandidateState()
        _ = state.matched(entryID: 0xFEED00000042, service: .device, location: "External")
        let registered = state.diagnosticCandidate(entryID: 0xFEED00000042)
        _ = state.invalidate(entryID: 0xFEED00000042, terminated: true)
        return ConnectionObservation(role: .controller, observerStartedAtNanoseconds: 100, continuousNs: 123,
            event: event, candidateOrdinal: 1, candidate: registered, registryScope: .other,
            messageType: nil, messageArgument: nil, messageClassification: messageClassification,
            observedLocation: nil, initial: nil,
            disposition: .revoked, invalidated: state.invalidated)
    }

    func testRevocationMarkerRetainsRegisteredRoleButNoRawIdentity() throws {
        let line = try connectionObservationMarker(observation())
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["type", "clock", "role", "observerStartedAtNanoseconds", "continuousNs",
                                        "event", "candidateOrdinal", "candidate", "registryScope", "disposition", "invalidated"])
        XCTAssertEqual(value["continuousNs"] as? UInt64, 123)
        XCTAssertEqual(value["candidateOrdinal"] as? UInt64, 1)
        XCTAssertEqual(value["invalidated"] as? Bool, true)
        let candidate = try XCTUnwrap(value["candidate"] as? [String: String])
        XCTAssertEqual(candidate, ["role": "registeredExternal", "service": "DCPAVDeviceProxy"])
        XCTAssertFalse(line.contains(String(UInt64(0xFEED00000042))))
        XCTAssertFalse(line.contains("entryID"))
    }

    func testInterestMarkerPreservesRawMessageAndUntrustedLocationClassification() throws {
        let marker = ConnectionObservation(role: .observer, observerStartedAtNanoseconds: 100, continuousNs: 124,
            event: .interest, candidateOrdinal: nil,
            candidate: ConnectionCandidateDiagnostic(role: .unidentified, service: nil), registryScope: .unknown,
            messageType: 0xe0115006, messageArgument: ConnectionObservedArgument(UnsafeMutableRawPointer(bitPattern: UInt.max)),
            messageClassification: .unknown, observedLocation: ConnectionObservedLocation("PRIVATE_LOCATION"),
            initial: false, disposition: .revoked, invalidated: true)
        let line = try connectionObservationMarker(marker)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(value["messageType"] as? UInt32, 0xe0115006)
        XCTAssertEqual(value["messageArgument"] as? String, "other")
        XCTAssertEqual(value["messageClassification"] as? String, "unknown")
        XCTAssertFalse(line.contains(String(UInt.max)))
        XCTAssertFalse(line.contains("0xffff"))
        XCTAssertEqual(value["observedLocation"] as? String, "other")
        XCTAssertFalse(line.contains("PRIVATE_LOCATION"))
        XCTAssertEqual(ConnectionObservedLocation(nil), .unavailable)
        XCTAssertEqual(ConnectionObservedLocation("External"), .external)
        XCTAssertEqual(ConnectionObservedLocation("Embedded"), .embedded)
        XCTAssertEqual(ConnectionObservedLocation("embedded"), .other)
    }

    func testMessageClassificationCoversAllKnownCodesAndLinkArguments() {
        let candidate = ConnectionCandidateDiagnostic(role: .registeredExternal, service: .device)
        let cases: [(UInt32, ConnectionMessageClassification, ConnectionMessageClassification)] = [
            (0xe0115000, .audioLinkStart, .videoLinkStart),
            (0xe0115001, .audioLinkStarted, .videoLinkStarted),
            (0xe0115004, .audioLinkStop, .videoLinkStop),
            (0xe0115005, .audioLinkStopped, .videoLinkStopped)
        ]

        for (messageType, audio, video) in cases {
            XCTAssertEqual(connectionMessageClassification(event: .interest, candidate: candidate,
                messageType: messageType, messageArgument: .zero), audio)
            XCTAssertEqual(connectionMessageClassification(event: .interest, candidate: candidate,
                messageType: messageType, messageArgument: .one), video)
            XCTAssertEqual(connectionMessageClassification(event: .interest, candidate: candidate,
                messageType: messageType, messageArgument: .other), .unknown)
            XCTAssertEqual(connectionMessageClassification(event: .interest, candidate: candidate,
                messageType: messageType, messageArgument: nil), .unknown)
        }

        for argument: ConnectionObservedArgument? in [.zero, .one, .other, nil] {
            XCTAssertEqual(connectionMessageClassification(event: .interest, candidate: candidate,
                messageType: 0xe0115006, messageArgument: argument), .protectionChanged)
        }
        XCTAssertEqual(connectionMessageClassification(event: .interest, candidate: candidate,
            messageType: 0xe01150ff, messageArgument: .zero), .unknown)
    }

    func testMessageClassificationRequiresRegisteredExternalCandidateAndInterestEvent() throws {
        let candidates = [
            ConnectionCandidateDiagnostic(role: .unregistered, service: .device),
            ConnectionCandidateDiagnostic(role: .unidentified, service: nil),
            ConnectionCandidateDiagnostic(role: .registeredEmbedded, service: .device),
            ConnectionCandidateDiagnostic(role: .retiredEmbedded, service: .device),
            ConnectionCandidateDiagnostic(role: .registeredExternal, service: nil)
        ]
        for candidate in candidates {
            XCTAssertEqual(connectionMessageClassification(event: .interest, candidate: candidate,
                messageType: 0xe0115006, messageArgument: .zero), .unknown)
            XCTAssertEqual(connectionMessageClassification(event: .interest, candidate: candidate,
                messageType: 0xe0115000, messageArgument: .zero), .unknown)
        }

        for service in ExternalConnectionService.allCases {
            let candidate = ConnectionCandidateDiagnostic(role: .registeredExternal, service: service)
            XCTAssertEqual(connectionMessageClassification(event: .interest, candidate: candidate,
                messageType: 0xe0115000, messageArgument: .zero), .audioLinkStart)
        }

        for event in [ConnectionObservationEvent.matched, .terminated, .watchFailed] {
            let classification = connectionMessageClassification(event: event,
                candidate: candidates[0], messageType: 0xe0115000, messageArgument: .zero)
            XCTAssertNil(classification)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(
                with: Data(try connectionObservationMarker(observation(event: event)).utf8)
            ) as? [String: Any])
            XCTAssertNil(value["messageClassification"])
        }

        let interestValue = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(try connectionObservationMarker(observation(event: .interest,
                messageClassification: .audioLinkStart)).utf8)
        ) as? [String: Any])
        XCTAssertEqual(interestValue["messageClassification"] as? String, "audioLinkStart")
    }

    func testProtectionDiagnosticSurvivesRevocationWithoutRestoringAuthority() {
        for service in ExternalConnectionService.allCases {
            var state = ConnectionCandidateState()
            XCTAssertTrue(state.matched(entryID: 42, service: service, location: "External"))
            XCTAssertEqual(state.invalidate(entryID: 42, terminated: false), service)

            // 诊断保留原登记角色；已知消息标签不是仍有效的登记证明。
            for _ in 0..<2 {
                XCTAssertEqual(connectionMessageClassification(
                    event: .interest, candidate: state.diagnosticCandidate(entryID: 42),
                    messageType: 0xe0115006, messageArgument: .one
                ), .protectionChanged)
                XCTAssertFalse(state.matched(entryID: 42, service: service, location: "External"))
                XCTAssertTrue(state.invalidated)
            }

            XCTAssertEqual(state.invalidate(entryID: 42, terminated: true), service)
            XCTAssertEqual(connectionMessageClassification(
                event: .interest, candidate: state.diagnosticCandidate(entryID: 42),
                messageType: 0xe0115006, messageArgument: .one
            ), .unknown)
            XCTAssertTrue(state.invalidated)
        }
    }

    func testArgumentClassificationDoesNotDereferenceOrInferLinkType() throws {
        let cases: [(UInt, ConnectionObservedArgument)] = [(0, .zero), (1, .one), (2, .two), (3, .other), (UInt.max, .other)]
        for (bits, expected) in cases {
            let argument = ConnectionObservedArgument(UnsafeMutableRawPointer(bitPattern: bits))
            XCTAssertEqual(argument, expected)
            XCTAssertEqual(String(decoding: try JSONEncoder().encode(argument), as: UTF8.self),
                           "\"\(expected.rawValue)\"")
        }
    }

    func testRegistryScopeDoesNotInferRelationshipBetweenDifferentObjects() {
        XCTAssertEqual(connectionRegistryScope(entryID: 0, target: 0, internalProof: 0), .unknown)
        XCTAssertEqual(connectionRegistryScope(entryID: 7, target: 7, internalProof: 7), .identityConflict)
        XCTAssertEqual(connectionRegistryScope(entryID: 7, target: 7, internalProof: 8), .target)
        XCTAssertEqual(connectionRegistryScope(entryID: 8, target: 7, internalProof: 8), .expectedInternal)
        XCTAssertEqual(connectionRegistryScope(entryID: 9, target: 7, internalProof: 8), .other)
        XCTAssertEqual(connectionRegistryScope(entryID: 9, target: 7, internalProof: nil), .other)
    }

    func testDisplayObservationEncodesOnlyApprovedFieldsAndPreservesRawFlagsAndReason() throws {
        let rawFlags = UInt32(0x8000_0000) | CGDisplayChangeSummaryFlags.disabledFlag.rawValue
        let flags = CGDisplayChangeSummaryFlags(rawValue: rawFlags)
        let reason = connectionChangeInvalidationReason(display: 9, flags: flags, expectedDisabledInternal: 7)
        let marker = ConnectionDisplayObservation(
            role: .controller, observerStartedAtNanoseconds: 100, continuousNs: 123,
            flags: rawFlags, scope: .other, invalidationReason: reason
        )

        let line = try connectionObservationMarker(marker)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["type", "clock", "role", "observerStartedAtNanoseconds", "continuousNs",
                                        "flags", "scope", "invalidationReason"])
        XCTAssertEqual(value["type"] as? String, "display-connection-observation")
        XCTAssertEqual(value["clock"] as? String, "mach_continuous_time/ns")
        XCTAssertEqual(value["continuousNs"] as? UInt64, 123)
        XCTAssertEqual(value["flags"] as? UInt32, rawFlags)
        XCTAssertEqual(value["scope"] as? String, "other")
        XCTAssertEqual(reason, "cg-disabled")
        XCTAssertEqual(value["invalidationReason"] as? String, reason)
        XCTAssertFalse(line.contains("displayID"))
        XCTAssertFalse(line.contains("registryID"))
        XCTAssertFalse(line.contains("UUID"))
    }

    func testDisplayObservationUsesOnlyUnknownExpectedInternalAndOtherScopes() {
        XCTAssertEqual(connectionDisplayScope(display: 0, expectedDisabledInternal: 7), .unknown)
        XCTAssertEqual(connectionDisplayScope(display: 7, expectedDisabledInternal: 7), .expectedInternal)
        XCTAssertEqual(connectionDisplayScope(display: 8, expectedDisabledInternal: 7), .other)
        XCTAssertEqual(connectionDisplayScope(display: 7, expectedDisabledInternal: 0), .other)
        XCTAssertEqual(connectionDisplayScope(display: 7, expectedDisabledInternal: nil), .other)

        XCTAssertEqual(ConnectionDisplayScope.expectedInternal.rawValue, "expected-internal")
    }

    func testDisplayObservationReasonReusesExistingFixedInvalidationResults() {
        XCTAssertNil(connectionChangeInvalidationReason(display: 7, flags: .disabledFlag,
                                                        expectedDisabledInternal: 7))
        XCTAssertEqual(connectionChangeInvalidationReason(display: 8, flags: .disabledFlag,
                                                          expectedDisabledInternal: 7), "cg-disabled")
        XCTAssertEqual(connectionChangeInvalidationReason(display: 8, flags: .removeFlag,
                                                          expectedDisabledInternal: 7), "cg-remove")
        XCTAssertNil(connectionChangeInvalidationReason(display: 7,
            flags: [.removeFlag, .disabledFlag, .desktopShapeChangedFlag], expectedDisabledInternal: 7))
    }

    func testSlowOutputDoesNotBlockObservationCaller() {
        let writerEntered = expectation(description: "writer entered")
        let callerReturned = expectation(description: "caller returned while output blocked")
        let outputFinished = expectation(description: "output completed")
        let release = DispatchSemaphore(value: 0)
        let marker = observation()
        DispatchQueue.global().async {
            traceConnectionObservation(marker) { _ in
                writerEntered.fulfill()
                _ = release.wait(timeout: .now() + 5)
                outputFinished.fulfill()
            }
            callerReturned.fulfill()
        }
        wait(for: [writerEntered, callerReturned], timeout: 2)
        release.signal()
        wait(for: [outputFinished], timeout: 2)
    }

    func testSlowDisplayObservationOutputDoesNotBlockProducer() {
        let outputEntered = DispatchSemaphore(value: 0)
        let releaseOutput = DispatchSemaphore(value: 0)
        let outputReturned = DispatchSemaphore(value: 0)
        let producerReturned = DispatchSemaphore(value: 0)
        let marker = ConnectionDisplayObservation(
            role: .observer, observerStartedAtNanoseconds: 100, continuousNs: 123,
            flags: 0x8000_0000, scope: .unknown, invalidationReason: nil
        )
        defer { releaseOutput.signal() }

        DispatchQueue.global().async {
            traceConnectionObservation(marker) { _ in
                outputEntered.signal()
                _ = releaseOutput.wait(timeout: .now() + 5)
                outputReturned.signal()
            }
            producerReturned.signal()
        }

        XCTAssertEqual(outputEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(producerReturned.wait(timeout: .now() + 2), .success)
        releaseOutput.signal()
        XCTAssertEqual(outputReturned.wait(timeout: .now() + 2), .success)
    }

    func testDrainStopsInFlightProducerThenWaitsForRevocationOutput() {
        let producer = DispatchQueue(label: "ConnectionObservationTests.producer")
        let control = DispatchQueue(label: "ConnectionObservationTests.control")
        let callbackEntered = DispatchSemaphore(value: 0)
        let releaseCallback = DispatchSemaphore(value: 0)
        let stopStarted = DispatchSemaphore(value: 0)
        let callbackReturned = DispatchSemaphore(value: 0)
        let outputEntered = DispatchSemaphore(value: 0)
        let releaseOutput = DispatchSemaphore(value: 0)
        let outputValidated = DispatchSemaphore(value: 0)
        let releaseOutputReturn = DispatchSemaphore(value: 0)
        let drainReturned = DispatchSemaphore(value: 0)
        let revocationMarkerObserved = DispatchSemaphore(value: 0)
        let malformedMarkerObserved = DispatchSemaphore(value: 0)
        let marker = observation()
        defer {
            releaseCallback.signal()
            releaseOutput.signal()
            releaseOutputReturn.signal()
        }

        producer.async {
            callbackEntered.signal()
            guard releaseCallback.wait(timeout: .now() + 5) == .success else {
                callbackReturned.signal()
                return
            }
            traceConnectionObservation(marker) { line in
                let value = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
                if value?["event"] as? String == ConnectionObservationEvent.terminated.rawValue,
                   value?["disposition"] as? String == ConnectionObservationDisposition.revoked.rawValue,
                   value?["invalidated"] as? Bool == true {
                    revocationMarkerObserved.signal()
                } else {
                    malformedMarkerObserved.signal()
                }
                outputEntered.signal()
                _ = releaseOutput.wait(timeout: .now() + 5)
                outputValidated.signal()
                _ = releaseOutputReturn.wait(timeout: .now() + 5)
            }
            callbackReturned.signal()
        }

        XCTAssertEqual(callbackEntered.wait(timeout: .now() + 2), .success)
        control.async {
            drainConnectionObservations(afterStoppingProducer: {
                stopStarted.signal()
                producer.sync {}
            })
            drainReturned.signal()
        }

        XCTAssertEqual(stopStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(drainReturned.wait(timeout: .now() + 0.1), .timedOut)

        releaseCallback.signal()
        XCTAssertEqual(callbackReturned.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(outputEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(revocationMarkerObserved.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(malformedMarkerObserved.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(drainReturned.wait(timeout: .now() + 0.1), .timedOut)

        releaseOutput.signal()
        XCTAssertEqual(outputValidated.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(drainReturned.wait(timeout: .now() + 0.1), .timedOut)

        releaseOutputReturn.signal()
        XCTAssertEqual(drainReturned.wait(timeout: .now() + 2), .success)
    }

    func testDrainHandlesEmptyProducerAndRepeatedCalls() {
        var stopCalls = 0

        drainConnectionObservations(afterStoppingProducer: { stopCalls += 1 })
        drainConnectionObservations(afterStoppingProducer: { stopCalls += 1 })

        XCTAssertEqual(stopCalls, 2)
    }

    func testCommonNativeStageCanBeExplicitlyIdentifiedAsDisable() throws {
        let line = try internalLifecycleMarker(.enableCompleteFinished, at: 125, mainThread: false,
                                               cgError: .success, operation: .disable)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(value["operation"] as? String, "disable")
        XCTAssertEqual(value["stage"] as? String, "enableCompleteFinished")
        XCTAssertEqual(value["cgErrorCode"] as? Int32, 0)
    }
}
