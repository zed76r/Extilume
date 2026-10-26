import Foundation
import XCTest
@testable import ExtilumeCore

final class ExternalRecoveryRecordTests: XCTestCase {
    private let internalID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let externalID = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!

    private var identity: ExternalDisplayIdentity {
        ExternalDisplayIdentity(
            uuid: externalID,
            registryPath: "IOService:/fixture/external-display",
            edidUUID: "fixture-edid-uuid",
            bootSession: UUID(uuidString: "10000000-0000-4000-8000-000000000003")!,
            registryEntryID: 42
        )
    }

    func testExternalIdentityRejectsIncompleteBinding() {
        let invalidIdentities = [
            ExternalDisplayIdentity(
                uuid: externalID, registryPath: " ", edidUUID: "edid",
                bootSession: UUID(), registryEntryID: 1
            ),
            ExternalDisplayIdentity(
                uuid: externalID, registryPath: "registry", edidUUID: "\n",
                bootSession: UUID(), registryEntryID: 1
            ),
            ExternalDisplayIdentity(
                uuid: externalID, registryPath: "registry", edidUUID: "edid",
                bootSession: UUID(), registryEntryID: 0
            )
        ]
        for invalidIdentity in invalidIdentities {
            XCTAssertThrowsError(try invalidIdentity.validate())
        }
    }

    func testV4ExternalResponsibilityRoundTripsAndPlansLatestC() throws {
        let c = try layout(mainExternal: true)
        let target = try layout()
        let internalOnly = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0)
        ])
        let responsibility = ExternalDisplayResponsibility(
            identity: identity, numericIDHint: 40, baseline: true, applied: false
        )
        var record = try RecoveryRecord(
            baseline: c, target: target, externalDisplay: responsibility
        )
        XCTAssertEqual(record.version, 4)

        try record.markApplying()
        try record.confirmApplied(internalOnly, internalEnabled: true, externalEnabled: false)
        XCTAssertEqual(record.baseline, c)
        XCTAssertEqual(record.applied, internalOnly)
        XCTAssertEqual(record.preDisableLayout, target)
        XCTAssertTrue(record.requiresRecovery)
        try record.validate()

        let decoded = try JSONDecoder().decode(RecoveryRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        try decoded.validate()

        let externalPlan = try decoded.externalRestorePlan(connected: [
            ConnectedDisplay(identity: externalID, numericID: 99)
        ])
        XCTAssertEqual(externalPlan?.id, 99)
        XCTAssertEqual(externalPlan?.enabled, true)
        XCTAssertNil(try decoded.externalRestorePlan(connected: []))

        let subsetPlan = try decoded.layoutRestorePlan(connected: [
            ConnectedDisplay(identity: internalID, numericID: 90)
        ], current: internalOnly)
        XCTAssertEqual(subsetPlan.origins, [90: DisplayOrigin(x: 0, y: 0)])
        XCTAssertEqual(subsetPlan.missing, [externalID])

        let fullPlan = try decoded.layoutRestorePlan(connected: [
            ConnectedDisplay(identity: externalID, numericID: 40),
            ConnectedDisplay(identity: internalID, numericID: 90)
        ], current: target)
        XCTAssertEqual(fullPlan.origins[40], c.origins[externalID])
        XCTAssertEqual(fullPlan.origins[90], c.origins[internalID])
        XCTAssertTrue(fullPlan.missing.isEmpty)

        var restoring = decoded
        restoring.beginRestoration()
        XCTAssertThrowsError(try restoring.confirmRestored(
            actual: c, internalEnabled: true, externalEnabled: false
        ))
        XCTAssertTrue(restoring.externalDisplay?.pending == true)
        XCTAssertEqual(restoring.phase, .restoring)
        try restoring.confirmRestored(actual: c, internalEnabled: true, externalEnabled: true)
        XCTAssertFalse(restoring.requiresRecovery)
        XCTAssertTrue(restoring.canClear)
    }

    func testExternalConfirmationRequiresBothEnabledReadbacksAndOnlyInternalLayout() throws {
        let target = try layout()
        let internalOnly = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0)
        ])
        let responsibility = ExternalDisplayResponsibility(
            identity: identity, numericIDHint: 40, baseline: true, applied: false
        )
        let wrongResults: [(DisplayLayout, Bool?, Bool?)] = [
            (internalOnly, false, false),
            (internalOnly, true, true),
            (internalOnly, true, nil),
            (target, true, false)
        ]
        for (actual, internalEnabled, externalEnabled) in wrongResults {
            var record = try RecoveryRecord(
                baseline: try layout(mainExternal: true), target: target, externalDisplay: responsibility
            )
            try record.markApplying()
            XCTAssertThrowsError(try record.confirmApplied(
                actual, internalEnabled: internalEnabled, externalEnabled: externalEnabled
            ))
            XCTAssertTrue(record.sourceUnresolved)
            XCTAssertEqual(record.applied, target)
            XCTAssertNil(record.preDisableLayout)
            XCTAssertTrue(record.externalDisplay?.pending == true)
        }
    }

    func testExternalAndInternalDisableResponsibilitiesCannotOverlap() throws {
        let internalResponsibility = InternalDisplayResponsibility(
            identity: internalID, baseline: true, applied: false
        )
        let externalResponsibility = ExternalDisplayResponsibility(
            identity: identity, numericIDHint: 40, baseline: true, applied: false
        )
        XCTAssertThrowsError(try RecoveryRecord(
            baseline: try layout(), target: try layout(),
            internalDisplay: internalResponsibility, externalDisplay: externalResponsibility
        ))
    }

    func testPartialAndApplicationIntermediateLayoutsNeverReplaceC() throws {
        let c = try layout(mainExternal: true)
        let target = try layout()
        let internalOnly = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0)
        ])
        let responsibility = ExternalDisplayResponsibility(
            identity: identity, numericIDHint: 40, baseline: true, applied: false
        )
        var owned = try RecoveryRecord(baseline: c, target: target, externalDisplay: responsibility)
        try owned.markApplying()
        try owned.confirmApplied(internalOnly, internalEnabled: true, externalEnabled: false)

        var observed = owned
        try observed.observe(internalOnly, source: .ownCallback)
        XCTAssertEqual(observed.baseline, c)
        XCTAssertThrowsError(try observed.observe(internalOnly, source: .unknown))
        XCTAssertEqual(observed.baseline, c)
        XCTAssertThrowsError(try observed.observe(internalOnly, source: .confirmedUser))
        XCTAssertEqual(observed.baseline, c)

        var intermediate = owned
        XCTAssertThrowsError(try intermediate.observe(target, source: .ownCallback))
        XCTAssertEqual(intermediate.baseline, c)

        var prepared = owned
        try prepared.prepareReapplication(current: internalOnly, target: target)
        XCTAssertEqual(prepared.baseline, c)
        XCTAssertNil(prepared.preDisableLayout)
        XCTAssertEqual(prepared.applied, target)
        XCTAssertThrowsError(try prepared.prepareReapplication(current: target, target: internalOnly))
    }

    func testConfirmedFullUserLayoutBecomesCAndRemainsUncoveredByRestorePlan() throws {
        let originalC = try layout(mainExternal: true)
        let target = try layout()
        let internalOnly = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0)
        ])
        let userC = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 2048, y: 200)
        ])
        let responsibility = ExternalDisplayResponsibility(
            identity: identity, numericIDHint: 40, baseline: true, applied: false
        )
        var record = try RecoveryRecord(baseline: originalC, target: target, externalDisplay: responsibility)
        try record.markApplying()
        try record.confirmApplied(internalOnly, internalEnabled: true, externalEnabled: false)

        try record.observeExternalEnabled(true, source: .confirmedUser)
        try record.observe(userC, source: .confirmedUser)
        XCTAssertEqual(record.baseline, userC)
        XCTAssertFalse(record.layoutPending)

        record.beginRestoration()
        let plan = try record.layoutRestorePlan(connected: [
            ConnectedDisplay(identity: internalID, numericID: 90),
            ConnectedDisplay(identity: externalID, numericID: 40)
        ], current: userC)
        XCTAssertTrue(plan.origins.isEmpty)
        XCTAssertTrue(plan.missing.isEmpty)
        try record.confirmRestored(actual: userC, internalEnabled: true, externalEnabled: true)
        XCTAssertTrue(record.canClear)
    }

    func testConfirmedPreDisableIntermediateCannotReplaceC() throws {
        let c = try layout(mainExternal: true)
        let target = try layout()
        let internalOnly = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0)
        ])
        let responsibility = ExternalDisplayResponsibility(
            identity: identity, numericIDHint: 40, baseline: true, applied: false
        )
        var record = try RecoveryRecord(baseline: c, target: target, externalDisplay: responsibility)
        try record.markApplying()
        try record.confirmApplied(internalOnly, internalEnabled: true, externalEnabled: false)

        XCTAssertThrowsError(try record.observe(target, source: .confirmedUser))
        XCTAssertEqual(record.baseline, c)
        XCTAssertTrue(record.sourceUnresolved)
    }

    func testSettledRecordAcceptsExplicitNewUserLayoutButRejectsOldIntermediate() throws {
        let oldC = try layout(mainExternal: true)
        let userC = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 2048, y: 200)
        ])
        var record = try restoredRecord()

        XCTAssertThrowsError(try record.confirmExternalUserLayout(
            layout(), internalEnabled: true, externalEnabled: true
        ))
        XCTAssertEqual(record.baseline, oldC)

        try record.confirmExternalUserLayout(userC, internalEnabled: true, externalEnabled: true)
        XCTAssertEqual(record.baseline, userC)
        XCTAssertFalse(record.layoutPending)
        XCTAssertFalse(record.externalDisplay?.pending ?? true)
        XCTAssertEqual(record.phase, .owned)
        XCTAssertFalse(record.canClear)
        try record.validate()
    }

    func testNonClearableRestoredRecordCannotConfirmExternalUserLayout() throws {
        let settled = try restoredRecord()
        var json = try jsonObject(settled)
        var external = try XCTUnwrap(json["externalDisplay"] as? [String: Any])
        external["pending"] = true
        json["externalDisplay"] = external
        var malformed = try decode(json)
        XCTAssertFalse(malformed.canClear)

        XCTAssertThrowsError(try malformed.confirmExternalUserLayout(
            layout(mainExternal: true), internalEnabled: true, externalEnabled: true
        )) { error in
            guard case RecoveryError.invalidRecord = error else {
                return XCTFail("Expected invalidRecord, got \(error)")
            }
        }
    }

    func testV1ThroughV3RecordsWithoutExternalFieldRemainReadable() throws {
        let base = try RecoveryRecord(baseline: layout(), target: layout())
        var v1JSON = try jsonObject(base)
        v1JSON["version"] = 1
        let v1 = try decode(v1JSON)
        XCTAssertEqual(v1.version, 1)
        try v1.validate()

        var v2JSON = try jsonObject(base)
        v2JSON.removeValue(forKey: "externalDisplay")
        let v2 = try decode(v2JSON)
        XCTAssertEqual(v2.version, 2)
        try v2.validate()

        let hardware = InternalDisplayHardwareIdentity(
            bootSession: UUID(uuidString: "10000000-0000-4000-8000-000000000004")!, registryEntryID: 7
        )
        let v3Record = try RecoveryRecord(
            baseline: layout(), target: layout(),
            internalDisplay: InternalDisplayResponsibility(
                identity: internalID, baseline: true, applied: true, hardwareIdentity: hardware
            )
        )
        var v3JSON = try jsonObject(v3Record)
        v3JSON.removeValue(forKey: "externalDisplay")
        let v3 = try decode(v3JSON)
        XCTAssertEqual(v3.version, 3)
        try v3.validate()

        var unknownJSON = try jsonObject(base)
        unknownJSON["version"] = 99
        XCTAssertThrowsError(try decode(unknownJSON).validate())
    }

    private func layout(mainExternal: Bool = false) throws -> DisplayLayout {
        try DisplayLayout(main: mainExternal ? externalID : internalID, origins: [
            internalID: DisplayOrigin(x: mainExternal ? -1920 : 0, y: 0),
            externalID: DisplayOrigin(x: mainExternal ? 0 : 1920, y: 0)
        ])
    }

    private func restoredRecord() throws -> RecoveryRecord {
        let baseline = try layout(mainExternal: true)
        let target = try layout()
        let internalOnly = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0)
        ])
        var record = try RecoveryRecord(
            baseline: baseline, target: target,
            externalDisplay: ExternalDisplayResponsibility(identity: identity, numericIDHint: 40,
                                                           baseline: true, applied: false)
        )
        try record.markApplying()
        try record.confirmApplied(internalOnly, internalEnabled: true, externalEnabled: false)
        record.beginRestoration()
        try record.confirmRestored(actual: baseline, internalEnabled: true, externalEnabled: true)
        return record
    }

    private func jsonObject(_ record: RecoveryRecord) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
    }

    private func decode(_ json: [String: Any]) throws -> RecoveryRecord {
        try JSONDecoder().decode(RecoveryRecord.self, from: JSONSerialization.data(withJSONObject: json))
    }
}
