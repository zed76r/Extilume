import CoreGraphics
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class InternalLifecycleTimingTests: XCTestCase {
    func testMarkerContainsOnlyFixedLabelsClockAndOutcome() throws {
        let line = try internalLifecycleMarker(.powerAcknowledged, role: .controller,
                                               at: 123_456, mainThread: false, succeeded: false)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["type", "clock", "role", "stage", "continuousNs", "mainThread", "succeeded"])
        XCTAssertEqual(value["type"] as? String, "internal-lifecycle")
        XCTAssertEqual(value["clock"] as? String, "mach_continuous_time/ns")
        XCTAssertEqual(value["stage"] as? String, "powerAcknowledged")
        XCTAssertEqual(value["continuousNs"] as? UInt64, 123_456)
        XCTAssertEqual(value["mainThread"] as? Bool, false)
        XCTAssertEqual(value["succeeded"] as? Bool, false)
    }

    func testWitnessReadMarkerContainsOnlyFixedStageAndHintPresence() throws {
        let identityCanary = "00000000-0000-4000-8000-123456789abc"
        let numericIDCanary = "987654321"
        let line = try internalLifecycleMarker(
            .witnessReadStarted,
            role: .witness,
            at: 123,
            mainThread: false,
            isNumericHint: true
        )
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])

        XCTAssertEqual(Set(value.keys), [
            "type", "clock", "role", "stage", "continuousNs", "mainThread", "isNumericHint"
        ])
        XCTAssertEqual(value["role"] as? String, "witness")
        XCTAssertEqual(value["stage"] as? String, "witnessReadStarted")
        XCTAssertEqual(value["isNumericHint"] as? Bool, true)
        XCTAssertFalse(line.contains(identityCanary))
        XCTAssertFalse(line.contains(numericIDCanary))
        XCTAssertFalse(line.contains("registryEntryID"))
    }

    func testIncompleteStageHasNoInventedSuccess() throws {
        let line = try internalLifecycleMarker(.enableStarted, role: .helper, at: 1, mainThread: true)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertNil(value["succeeded"])
        XCTAssertEqual(value["role"] as? String, "helper")
    }

    func testNativeResultPreservesRawCodeAndOutcome() throws {
        for result in [CGError.success, .failure] {
            let line = try internalLifecycleMarker(.enableCompleteFinished, at: 2, mainThread: false, cgError: result)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(value["stage"] as? String, "enableCompleteFinished")
            XCTAssertEqual(value["cgErrorCode"] as? Int32, result.rawValue)
            XCTAssertEqual(value["succeeded"] as? Bool, result == .success)
            XCTAssertNil(value["failureCode"])
        }
    }

    func testRestorationFailureUsesFixedNativeAndRecordCategories() throws {
        let failures: [(Error, String)] = [
            (DisplayEnableTransactionError.symbolUnavailable, "enable-symbol-unavailable"),
            (DisplayEnableTransactionError.invalidDisplay, "enable-invalid-display"),
            (DisplayEnableTransactionError.beginFailed, "enable-begin-failed"),
            (DisplayEnableTransactionError.configurationFailed, "enable-configure-failed"),
            (DisplayEnableTransactionError.commitFailed, "enable-complete-failed"),
            (DisplayEnableTransactionError.unsafeTopology, "enable-unsafe-topology"),
            (RecoveryError.identityConflict, "identity-conflict"),
            (RecoveryError.invalidRecord, "recovery-invalid-record"),
            (RecoveryError.unresolvedSource, "recovery-unresolved-source"),
            (RecoveryError.unfinishedTransaction, "recovery-unfinished-transaction"),
            (RecoveryError.invalidTransition, "recovery-invalid-transition"),
            (RecoveryStoreError.ioFailure, "recovery-store")
        ]
        for (error, code) in failures {
            let line = try internalLifecycleMarker(.restorationFailed, role: .helper, at: 3,
                                                   mainThread: false, succeeded: false, error: error)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(value["failureCode"] as? String, code)
            XCTAssertEqual(value["succeeded"] as? Bool, false)
            XCTAssertNil(value["cgErrorCode"])
        }
    }

    func testRejectedLayoutMarkerContainsOnlyAnonymousRelationships() throws {
        let internalID = UUID(uuidString: "00000000-0000-4000-8000-123456789abc")!
        let externalID = UUID(uuidString: "00000000-0000-4000-8000-abcdef012345")!
        let baseline = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0), externalID: DisplayOrigin(x: 12345, y: 0)
        ])
        let record = try RecoveryRecord(baseline: baseline, target: baseline,
            internalDisplay: InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false))
        let current = try DisplayLayout(main: externalID, origins: [externalID: DisplayOrigin(x: 0, y: 0)])
        let line = try internalLifecycleMarker(.layoutRestoreRejected, role: .helper, at: 4, mainThread: false,
            succeeded: false, recoveryLayout: InternalRecoveryLayoutContext(record: record, current: current))
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let context = try XCTUnwrap(value["recoveryLayout"] as? [String: Any])
        XCTAssertEqual(Set(context.keys), ["matchesBaseline", "matchesApplied", "matchesPreDisable",
            "matchesBaselineDisplaySet", "isBaselineDisplaySubset", "layoutPending", "internalPending", "sourceUnresolved"])
        XCTAssertEqual(context["matchesBaseline"] as? Bool, false)
        XCTAssertEqual(context["isBaselineDisplaySubset"] as? Bool, true)
        XCTAssertTrue(context.values.allSatisfy { $0 is NSNumber })
        XCTAssertFalse(line.contains(internalID.uuidString))
        XCTAssertFalse(line.contains(externalID.uuidString))
        XCTAssertFalse(line.contains("12345"))
    }

    func testUnknownErrorNeverSerializesItsDomainOrDescription() throws {
        let error = NSError(domain: "PRIVATE_DOMAIN_CANARY", code: 7,
                            userInfo: [NSLocalizedDescriptionKey: "PRIVATE_DESCRIPTION_CANARY"])
        let line = try internalLifecycleMarker(.restorationFailed, at: 4, mainThread: false,
                                               succeeded: false, error: error)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(value["failureCode"] as? String, "unclassified")
        XCTAssertFalse(line.contains("CANARY"))
        XCTAssertEqual(Set(value.keys), ["type", "clock", "role", "stage", "continuousNs", "mainThread", "succeeded", "failureCode"])
    }
}
