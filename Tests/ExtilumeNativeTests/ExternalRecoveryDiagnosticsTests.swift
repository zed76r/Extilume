import Foundation
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

final class ExternalRecoveryDiagnosticsTests: XCTestCase {
    private let internalID = UUID(uuidString: "10000000-0000-4000-8000-000000000041")!
    private let externalID = UUID(uuidString: "10000000-0000-4000-8000-000000000042")!
    private let bootID = UUID(uuidString: "10000000-0000-4000-8000-000000000043")!
    private let changedBootID = UUID(uuidString: "10000000-0000-4000-8000-000000000044")!
    private let hint: UInt32 = 78123
    private let registryLocation = "IOService:/fixture/diagnostic-only-path"
    private let edidUUID = "fixture-edid-identifier"

    private var recordIdentity: ExternalDisplayIdentity {
        ExternalDisplayIdentity(
            uuid: externalID,
            registryPath: registryLocation,
            edidUUID: edidUUID,
            bootSession: bootID,
            registryEntryID: 87654321
        )
    }

    private func record(internalDisplay: InternalDisplayResponsibility? = nil) throws -> RecoveryRecord {
        let layout = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 1920, y: 0)
        ])
        return try RecoveryRecord(
            baseline: layout,
            target: layout,
            internalDisplay: internalDisplay,
            externalDisplay: ExternalDisplayResponsibility(
                identity: recordIdentity, numericIDHint: hint, baseline: true, applied: false
            )
        )
    }

    private func snapshot(
        currentBootSession: UUID? = UUID(uuidString: "10000000-0000-4000-8000-000000000043")!,
        coreDisplayInfo: [String: Any]? = [
            "kCGDisplayID": NSNumber(value: 78123),
            "DisplayUUID": "10000000-0000-4000-8000-000000000042",
            "IODisplayLocation": "IOService:/fixture/diagnostic-only-path"
        ],
        colorSyncUUID: UUID? = UUID(uuidString: "10000000-0000-4000-8000-000000000042")!,
        colorSyncReverseDisplayID: UInt32 = 78123,
        privateDisplayList: ExternalRecoveryPrivateDisplayListSnapshot = .init(
            apiFound: true, readSucceeded: true, count: 2, containsHint: true
        ),
        registry: ExternalRecoveryRegistrySnapshot = .init(
            serviceFound: true, classMatches: true, entryIDMatches: true, pathMatches: true,
            isHDMI: true, edidUUIDPresent: true, edidUUIDMatches: true,
            edidDataPresent: true, edidByteCount: 128
        )
    ) -> ExternalRecoveryDiagnosticSnapshot {
        ExternalRecoveryDiagnosticSnapshot(
            currentBootSession: currentBootSession,
            numericHintIsBuiltin: false,
            numericHintIsOnline: true,
            numericHintIsActive: true,
            coreDisplayInfo: coreDisplayInfo,
            colorSyncUUID: colorSyncUUID,
            colorSyncReverseDisplayID: colorSyncReverseDisplayID,
            privateDisplayList: privateDisplayList,
            registry: registry
        )
    }

    private func jsonReport(
        for record: RecoveryRecord,
        snapshot: ExternalRecoveryDiagnosticSnapshot
    ) throws -> (String, [String: Any]) {
        let text = try makeExternalRecoveryDiagnosticReport(for: record, snapshot: snapshot)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        return (text, json)
    }

    func testReportHasOnlyFixedScalarKeysAndRedactsEveryRecordIdentifier() throws {
        let record = try record()
        let (text, json) = try jsonReport(for: record, snapshot: snapshot())
        let expectedKeys: Set<String> = [
            "diagnosticOnly", "currentBootAvailable", "currentBootMatches",
            "numericHintIsBuiltin", "numericHintIsOnline", "numericHintIsActive",
            "coreDisplayInfoAvailable", "coreDisplayReportedIDMatches", "coreDisplayUUIDPresent",
            "coreDisplayUUIDIsZero", "coreDisplayUUIDMatches", "coreDisplayRegistryLocationMatches",
            "colorSyncUUIDPresent", "colorSyncUUIDIsZero", "colorSyncUUIDMatches",
            "colorSyncReverseDisplayIDAvailable", "colorSyncReverseDisplayIDMatchesHint",
            "privateDisplayListAPIFound", "privateDisplayListReadSucceeded", "privateDisplayListCount",
            "privateDisplayListContainsHint", "registryServiceFound", "registryClassMatches",
            "registryEntryIDMatches", "registryPathMatches", "registryTransportIsHDMI",
            "registryEDIDUUIDPresent", "registryEDIDUUIDMatches", "registryEDIDDataPresent",
            "registryEDIDByteCount"
        ]
        XCTAssertEqual(Set(json.keys), expectedKeys)
        XCTAssertEqual(json["diagnosticOnly"] as? Bool, true)
        XCTAssertTrue(json["coreDisplayReportedIDMatches"] as? Bool == true)
        XCTAssertTrue(json["colorSyncReverseDisplayIDMatchesHint"] as? Bool == true)
        XCTAssertFalse(json.keys.contains("canRestore"))

        for identifier in [
            externalID.uuidString, bootID.uuidString, registryLocation, edidUUID,
            String(hint), "87654321"
        ] {
            XCTAssertFalse(text.contains(identifier))
        }
    }

    func testZeroUUIDsAreReportedWithoutSerializingThem() throws {
        let zero = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
        let coreInfo: [String: Any] = [
            "kCGDisplayID": NSNumber(value: hint),
            "kCGDisplayUUID": zero.uuidString,
            "IODisplayLocation": registryLocation
        ]
        let (text, json) = try jsonReport(
            for: record(), snapshot: snapshot(coreDisplayInfo: coreInfo, colorSyncUUID: zero)
        )
        XCTAssertEqual(json["coreDisplayUUIDPresent"] as? Bool, true)
        XCTAssertEqual(json["coreDisplayUUIDIsZero"] as? Bool, true)
        XCTAssertEqual(json["coreDisplayUUIDMatches"] as? Bool, false)
        XCTAssertEqual(json["colorSyncUUIDPresent"] as? Bool, true)
        XCTAssertEqual(json["colorSyncUUIDIsZero"] as? Bool, true)
        XCTAssertEqual(json["colorSyncUUIDMatches"] as? Bool, false)
        XCTAssertFalse(text.contains(zero.uuidString))
    }

    func testMissingEDIDDataAndDifferentBootRemainReadOnlyFacts() throws {
        let registry = ExternalRecoveryRegistrySnapshot(
            serviceFound: true, classMatches: true, entryIDMatches: true, pathMatches: true,
            isHDMI: true, edidUUIDPresent: false, edidUUIDMatches: false,
            edidDataPresent: false, edidByteCount: 0
        )
        let (_, json) = try jsonReport(
            for: record(), snapshot: snapshot(currentBootSession: changedBootID, registry: registry)
        )
        XCTAssertEqual(json["currentBootAvailable"] as? Bool, true)
        XCTAssertEqual(json["currentBootMatches"] as? Bool, false)
        XCTAssertEqual(json["registryEDIDUUIDPresent"] as? Bool, false)
        XCTAssertEqual(json["registryEDIDUUIDMatches"] as? Bool, false)
        XCTAssertEqual(json["registryEDIDDataPresent"] as? Bool, false)
        XCTAssertEqual(json["registryEDIDByteCount"] as? Int, 0)
        XCTAssertEqual(json["diagnosticOnly"] as? Bool, true)
    }

    func testColorSyncMismatchIsReportedAsComparisonOnly() throws {
        let otherUUID = UUID(uuidString: "20000000-0000-4000-8000-000000000042")!
        let (_, json) = try jsonReport(
            for: record(), snapshot: snapshot(colorSyncUUID: otherUUID)
        )
        XCTAssertEqual(json["colorSyncUUIDPresent"] as? Bool, true)
        XCTAssertEqual(json["colorSyncUUIDIsZero"] as? Bool, false)
        XCTAssertEqual(json["colorSyncUUIDMatches"] as? Bool, false)
    }

    func testMissingPrivateListAPIAndReverseIDZeroAreUnavailable() throws {
        let noPrivateAPI = ExternalRecoveryPrivateDisplayListSnapshot(
            apiFound: false, readSucceeded: false, count: 0, containsHint: false
        )
        let (_, json) = try jsonReport(
            for: record(),
            snapshot: snapshot(colorSyncReverseDisplayID: 0, privateDisplayList: noPrivateAPI)
        )
        XCTAssertEqual(json["privateDisplayListAPIFound"] as? Bool, false)
        XCTAssertEqual(json["privateDisplayListReadSucceeded"] as? Bool, false)
        XCTAssertEqual(json["privateDisplayListCount"] as? Int, 0)
        XCTAssertEqual(json["privateDisplayListContainsHint"] as? Bool, false)
        XCTAssertEqual(json["colorSyncReverseDisplayIDAvailable"] as? Bool, false)
        XCTAssertEqual(json["colorSyncReverseDisplayIDMatchesHint"] as? Bool, false)
    }

    func testMissingCoreDisplayInformationAndInvalidRecordFormatsAreRejectedSafely() throws {
        let (_, json) = try jsonReport(for: record(), snapshot: snapshot(coreDisplayInfo: nil))
        XCTAssertEqual(json["coreDisplayInfoAvailable"] as? Bool, false)
        XCTAssertEqual(json["coreDisplayUUIDPresent"] as? Bool, false)

        let layout = try DisplayLayout(main: internalID, origins: [internalID: DisplayOrigin(x: 0, y: 0)])
        let legacyRecord = try RecoveryRecord(baseline: layout, target: layout)
        XCTAssertThrowsError(try makeExternalRecoveryDiagnosticReport(for: legacyRecord, snapshot: snapshot()))

        let valid = try record()
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        value["version"] = 99
        let unknownData = try JSONSerialization.data(withJSONObject: value)
        let unknownRecord = try JSONDecoder().decode(RecoveryRecord.self, from: unknownData)
        XCTAssertThrowsError(try makeExternalRecoveryDiagnosticReport(for: unknownRecord, snapshot: snapshot()))

        var zeroHintValue = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        var external = try XCTUnwrap(zeroHintValue["externalDisplay"] as? [String: Any])
        external["numericIDHint"] = 0
        zeroHintValue["externalDisplay"] = external
        let zeroHintData = try JSONSerialization.data(withJSONObject: zeroHintValue)
        let zeroHintRecord = try JSONDecoder().decode(RecoveryRecord.self, from: zeroHintData)
        XCTAssertThrowsError(try makeExternalRecoveryDiagnosticReport(for: zeroHintRecord, snapshot: snapshot()))

        let internalResponsibility = InternalDisplayResponsibility(
            identity: internalID, baseline: false, applied: false
        )
        XCTAssertThrowsError(try makeExternalRecoveryDiagnosticReport(
            for: record(internalDisplay: internalResponsibility), snapshot: snapshot()
        ))
    }
}
