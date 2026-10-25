import Foundation
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

final class InternalDisplayReadDiagnosticsTests: XCTestCase {
    func testUnavailableCandidateIsClassifiedWithoutChangingNilResult() {
        let cases: [([String: Any]?, InternalDisplayCandidateFailure)] = [
            (nil, .informationUnavailable),
            (["kCGDisplayID": 8], .numericIDMismatch),
            (["kCGDisplayID": 7], .missingUUID),
            (["kCGDisplayID": 7, "DisplayUUID": "private-invalid-value"], .malformedUUID)
        ]
        for (info, expected) in cases {
            var reasons: [InternalDisplayCandidateFailure] = []
            XCTAssertNil(internalDisplayReportedIdentity(in: info, numericID: 7) { reasons.append($0) })
            XCTAssertEqual(reasons, [expected])
        }
    }

    func testBothUUIDKeysAndTheirExistingPrecedenceArePreserved() throws {
        let identity = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
        for key in ["DisplayUUID", "kCGDisplayUUID"] {
            XCTAssertEqual(internalDisplayReportedIdentity(
                in: ["kCGDisplayID": 7, key: identity.uuidString], numericID: 7,
                diagnostic: { _ in XCTFail("Readable identity must not emit a failure") }
            ), identity)
        }
        var reasons: [InternalDisplayCandidateFailure] = []
        XCTAssertNil(internalDisplayReportedIdentity(
            in: ["kCGDisplayID": 7, "DisplayUUID": "invalid", "kCGDisplayUUID": identity.uuidString],
            numericID: 7, diagnostic: { reasons.append($0) }
        ))
        XCTAssertEqual(reasons, [.malformedUUID])
    }

    func testTemporaryInformationAbsenceRequiresOnlyHintNoMatchAndCurrentProof() {
        let boot = UUID(uuidString: "00000000-0000-4000-8000-000000000021")!
        let proof = InternalDisplayHardwareIdentity(bootSession: boot, registryEntryID: 42)
        XCTAssertTrue(canReportInternalInformationUnavailable(
            identityFailure: .noMatch,
            numericHintFailure: .informationUnavailable,
            otherCandidateFailure: false,
            builtInConflict: false,
            hardwareIdentity: proof,
            currentBootSession: boot
        ))

        XCTAssertFalse(canReportInternalInformationUnavailable(
            identityFailure: .ambiguousMatch,
            numericHintFailure: .informationUnavailable,
            otherCandidateFailure: false,
            builtInConflict: false,
            hardwareIdentity: proof,
            currentBootSession: boot
        ))
        for failure in [InternalDisplayCandidateFailure.numericIDMismatch, .missingUUID, .malformedUUID] {
            XCTAssertFalse(canReportInternalInformationUnavailable(
                identityFailure: .noMatch,
                numericHintFailure: failure,
                otherCandidateFailure: false,
                builtInConflict: false,
                hardwareIdentity: proof,
                currentBootSession: boot
            ))
        }
        XCTAssertFalse(canReportInternalInformationUnavailable(
            identityFailure: .noMatch,
            numericHintFailure: nil,
            otherCandidateFailure: false,
            builtInConflict: false,
            hardwareIdentity: proof,
            currentBootSession: boot
        ))
        // Duplicate UUIDs among readable candidates set this rejection gate before noMatch is classified.
        let duplicateCandidateUUIDsAreConflict = true
        XCTAssertFalse(canReportInternalInformationUnavailable(
            identityFailure: .noMatch,
            numericHintFailure: .informationUnavailable,
            otherCandidateFailure: duplicateCandidateUUIDsAreConflict,
            builtInConflict: false,
            hardwareIdentity: proof,
            currentBootSession: boot
        ))
        XCTAssertFalse(canReportInternalInformationUnavailable(
            identityFailure: .noMatch,
            numericHintFailure: .informationUnavailable,
            otherCandidateFailure: false,
            builtInConflict: true,
            hardwareIdentity: proof,
            currentBootSession: boot
        ))
        XCTAssertFalse(canReportInternalInformationUnavailable(
            identityFailure: .noMatch,
            numericHintFailure: .informationUnavailable,
            otherCandidateFailure: false,
            builtInConflict: false,
            hardwareIdentity: nil,
            currentBootSession: boot
        ))
        XCTAssertFalse(canReportInternalInformationUnavailable(
            identityFailure: .noMatch,
            numericHintFailure: .informationUnavailable,
            otherCandidateFailure: false,
            builtInConflict: false,
            hardwareIdentity: proof,
            currentBootSession: UUID(uuidString: "00000000-0000-4000-8000-000000000022")!
        ))
        XCTAssertFalse(canReportInternalInformationUnavailable(
            identityFailure: .noMatch,
            numericHintFailure: .informationUnavailable,
            otherCandidateFailure: false,
            builtInConflict: false,
            hardwareIdentity: InternalDisplayHardwareIdentity(bootSession: boot, registryEntryID: 0),
            currentBootSession: boot
        ))
    }

    func testDiagnosticMarkerIncludesTimeAndFixedReasonWithoutCandidateIdentity() throws {
        let line = try internalLifecycleMarker(.internalCandidateUnavailable, role: .witness,
            at: 123, mainThread: false, succeeded: false,
            candidateFailure: .malformedUUID, isNumericHint: true)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["type", "clock", "role", "stage", "continuousNs", "mainThread",
                                        "succeeded", "candidateFailure", "isNumericHint"])
        XCTAssertEqual(value["candidateFailure"] as? String, "malformedUUID")
        XCTAssertEqual(value["continuousNs"] as? UInt64, 123)
        XCTAssertEqual(value["isNumericHint"] as? Bool, true)
        let rejected = try internalLifecycleMarker(.internalIdentityRejected, role: .witness,
            at: 124, mainThread: false, succeeded: false, identityFailure: .hardwareMismatch)
        let rejection = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(rejected.utf8)) as? [String: Any])
        XCTAssertEqual(rejection["identityFailure"] as? String, "hardwareMismatch")
        XCTAssertNil(rejection["candidateFailure"])
        XCTAssertNil(rejection["isNumericHint"])
    }
}
