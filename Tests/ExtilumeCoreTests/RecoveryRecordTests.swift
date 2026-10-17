import XCTest
@testable import ExtilumeCore

final class RecoveryRecordTests: XCTestCase {
    private let internalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let externalID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let otherID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!

    private func layout(mainExternal: Bool = false, distance: Int32 = 1728) throws -> DisplayLayout {
        try DisplayLayout(main: mainExternal ? externalID : internalID, origins: [
            internalID: DisplayOrigin(x: mainExternal ? -distance : 0, y: 0),
            externalID: DisplayOrigin(x: mainExternal ? 0 : distance, y: 0)
        ])
    }

    private func externalOnlyLayout() throws -> DisplayLayout {
        try DisplayLayout(main: externalID, origins: [externalID: DisplayOrigin(x: 0, y: 0)])
    }

    private func internalOnlyLayout() throws -> DisplayLayout {
        try DisplayLayout(main: internalID, origins: [internalID: DisplayOrigin(x: 0, y: 0)])
    }

    private func ownedRecord(internalDisplay: InternalDisplayResponsibility? = nil) throws -> RecoveryRecord {
        var record = try RecoveryRecord(baseline: layout(), target: layout(mainExternal: true), internalDisplay: internalDisplay)
        try record.markApplying()
        let actual = internalDisplay.map { $0.baseline && !$0.applied } == true
            ? try externalOnlyLayout()
            : try layout(mainExternal: true)
        try record.confirmApplied(actual, internalEnabled: internalDisplay?.applied)
        return record
    }

    func testDisabledLayoutUsesV2SubsetAndRestoresLatestCWithOrWithoutExternalDisplay() throws {
        let c = try layout(distance: -1920)
        let b = try layout(mainExternal: true)
        let subset = try externalOnlyLayout()
        let responsibility = InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false)
        var record = try RecoveryRecord(baseline: c, target: b, internalDisplay: responsibility)
        try record.markApplying()
        try record.confirmApplied(subset, internalEnabled: false)

        XCTAssertEqual(record.version, 2)
        XCTAssertEqual(record.baseline, c)
        XCTAssertEqual(record.applied, subset)
        XCTAssertEqual(record.preDisableLayout, b)
        XCTAssertTrue(record.layoutPending)
        XCTAssertEqual(record.phase, .owned)
        try record.validate()
        let decoded = try JSONDecoder().decode(RecoveryRecord.self, from: JSONEncoder().encode(record))
        try decoded.validate()
        XCTAssertEqual(decoded, record)

        let fullPlan = try record.layoutRestorePlan(connected: [
            ConnectedDisplay(identity: internalID, numericID: 90),
            ConnectedDisplay(identity: externalID, numericID: 40)
        ], current: b)
        XCTAssertEqual(fullPlan.origins[90], c.origins[internalID])
        XCTAssertEqual(fullPlan.origins[40], c.origins[externalID])
        XCTAssertTrue(fullPlan.missing.isEmpty)

        let partialPlan = try record.layoutRestorePlan(connected: [
            ConnectedDisplay(identity: internalID, numericID: 90)
        ], current: try internalOnlyLayout())
        XCTAssertEqual(partialPlan.origins, [90: DisplayOrigin(x: 0, y: 0)])
        XCTAssertEqual(partialPlan.missing, [externalID])

        var reapplication = decoded
        try reapplication.prepareReapplication(current: subset, target: b)
        XCTAssertNil(reapplication.preDisableLayout)
        XCTAssertEqual(reapplication.applied, b)
    }

    func testDisableConfirmationRejectsContradictoryOrUnprovenActualLayouts() throws {
        let b = try layout(mainExternal: true)
        let subset = try externalOnlyLayout()
        let responsibility = InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false)
        let invalidActuals: [(DisplayLayout, Bool?)] = [
            (b, false),
            (try internalOnlyLayout(), false),
            (subset, true),
            (subset, nil)
        ]
        for (actual, enabled) in invalidActuals {
            var record = try RecoveryRecord(baseline: layout(), target: b, internalDisplay: responsibility)
            try record.markApplying()
            XCTAssertThrowsError(try record.confirmApplied(actual, internalEnabled: enabled))
            XCTAssertTrue(record.sourceUnresolved)
            XCTAssertEqual(record.applied, b)
            XCTAssertNil(record.preDisableLayout)
        }

        var wrongMain = try RecoveryRecord(baseline: layout(), target: layout(), internalDisplay: responsibility)
        try wrongMain.markApplying()
        XCTAssertThrowsError(try wrongMain.confirmApplied(subset, internalEnabled: false))
        XCTAssertTrue(wrongMain.sourceUnresolved)

        let threeDisplayBaseline = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 1728, y: 0),
            otherID: DisplayOrigin(x: 3000, y: 0)
        ])
        let threeDisplayTarget = try DisplayLayout(main: externalID, origins: [
            internalID: DisplayOrigin(x: -1728, y: 0),
            externalID: DisplayOrigin(x: 0, y: 0),
            otherID: DisplayOrigin(x: 1200, y: 0)
        ])
        let wrongOrigin = try DisplayLayout(main: externalID, origins: [
            externalID: DisplayOrigin(x: 0, y: 0),
            otherID: DisplayOrigin(x: 1201, y: 0)
        ])
        var wrongOriginRecord = try RecoveryRecord(
            baseline: threeDisplayBaseline, target: threeDisplayTarget, internalDisplay: responsibility
        )
        try wrongOriginRecord.markApplying()
        XCTAssertThrowsError(try wrongOriginRecord.confirmApplied(wrongOrigin, internalEnabled: false))
        XCTAssertTrue(wrongOriginRecord.sourceUnresolved)

        var prepared = try RecoveryRecord(baseline: layout(), target: b, internalDisplay: responsibility)
        XCTAssertThrowsError(try prepared.confirmApplied(subset, internalEnabled: false))
        XCTAssertTrue(prepared.sourceUnresolved)

        var legacyJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(try applyingInternalDisableRecord(target: b))
        ) as? [String: Any])
        legacyJSON["version"] = 1
        legacyJSON.removeValue(forKey: "preDisableLayout")
        let legacyApplying = try JSONDecoder().decode(
            RecoveryRecord.self, from: JSONSerialization.data(withJSONObject: legacyJSON)
        )
        try legacyApplying.validate()
        var legacy = legacyApplying
        XCTAssertThrowsError(try legacy.confirmApplied(subset, internalEnabled: false))
        XCTAssertTrue(legacy.sourceUnresolved)
    }

    func testV1LegacyRecordStillDecodesAndRestoredSubsetHistoryRemainsValid() throws {
        var oldRecord = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(RecoveryRecord(baseline: layout(), target: layout(mainExternal: true)))
        ) as! [String: Any]
        oldRecord["version"] = 1
        oldRecord.removeValue(forKey: "preDisableLayout")
        let legacy = try JSONDecoder().decode(
            RecoveryRecord.self, from: JSONSerialization.data(withJSONObject: oldRecord)
        )
        XCTAssertEqual(legacy.version, 1)
        XCTAssertNil(legacy.preDisableLayout)
        try legacy.validate()

        let c = try layout(distance: -1920)
        let b = try layout(mainExternal: true)
        let responsibility = InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false)
        var record = try RecoveryRecord(baseline: c, target: b, internalDisplay: responsibility)
        try record.markApplying()
        try record.confirmApplied(try externalOnlyLayout(), internalEnabled: false)
        record.beginRestoration()
        try record.confirmRestored(actual: c, internalEnabled: true)
        XCTAssertEqual(record.phase, .restored)
        XCTAssertFalse(record.layoutPending)
        XCTAssertEqual(record.baseline, c)
        XCTAssertEqual(record.applied, try externalOnlyLayout())
        XCTAssertEqual(record.preDisableLayout, b)
        XCTAssertTrue(record.canClear)
        try record.validate()
        let restored = try JSONDecoder().decode(RecoveryRecord.self, from: JSONEncoder().encode(record))
        try restored.validate()
        XCTAssertEqual(restored.preDisableLayout, b)
    }

    private func applyingInternalDisableRecord(target: DisplayLayout) throws -> RecoveryRecord {
        var record = try RecoveryRecord(
            baseline: layout(), target: target,
            internalDisplay: InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false)
        )
        try record.markApplying()
        return record
    }

    func testLatestCIsRestoredAfterReapplication() throws {
        let b = try layout(mainExternal: true)
        let c = try layout(distance: -1920)
        var record = try ownedRecord()
        try record.observe(c, source: .confirmedUser)
        XCTAssertFalse(record.layoutPending)
        try record.prepareReapplication(current: c, target: b)
        try record.markApplying()
        try record.confirmApplied(b)
        XCTAssertEqual(record.baseline, c)
        record.beginRestoration()
        let plan = try record.layoutRestorePlan(connected: [
            ConnectedDisplay(identity: externalID, numericID: 40),
            ConnectedDisplay(identity: internalID, numericID: 90)
        ], current: b)
        XCTAssertEqual(plan.origins[40], c.origins[externalID])
        XCTAssertEqual(plan.origins[90], c.origins[internalID])
        try record.confirmRestored(actual: c)
        XCTAssertTrue(record.canClear)
    }

    func testDirectExitPreservesUncoveredC() throws {
        let c = try layout(distance: -1920)
        var record = try ownedRecord()
        try record.observe(c, source: .confirmedUser)
        record.beginRestoration()
        XCTAssertTrue(try record.layoutRestorePlan(connected: [], current: c).origins.isEmpty)
        try record.confirmRestored(actual: c)
        XCTAssertTrue(record.canClear)
        XCTAssertEqual(record.baseline, c)
    }

    func testExplicitReconfirmationOfBaselineClearsUnknownSource() throws {
        let c = try layout(distance: -1920)
        var record = try ownedRecord()
        try record.observe(c, source: .confirmedUser)
        XCTAssertThrowsError(try record.observe(layout(distance: 2400), source: .unknown))
        XCTAssertTrue(record.sourceUnresolved)
        try record.observe(c, source: .confirmedUser)
        XCTAssertEqual(record.baseline, c)
        XCTAssertFalse(record.sourceUnresolved)
        XCTAssertFalse(record.layoutPending)
    }

    func testDirectExitCannotConfirmAnUnobservedLayoutAsRestored() throws {
        var record = try ownedRecord()
        try record.observe(layout(distance: -1920), source: .confirmedUser)
        record.beginRestoration()
        XCTAssertThrowsError(try record.confirmRestored(actual: layout(distance: 2400)))
        XCTAssertEqual(record.phase, .restoring)
        XCTAssertFalse(record.canClear)
    }

    func testOwnCallbackAndReconnectedBDoNotReplaceA() throws {
        var record = try ownedRecord()
        let b = try layout(mainExternal: true)
        try record.observe(b, source: .ownCallback)
        try record.observe(b, source: .reconnect)
        try record.prepareReapplication(current: b, target: b)
        XCTAssertEqual(record.baseline, try layout())
        XCTAssertTrue(record.layoutPending)
    }

    func testReconnectedBRearmsRecoveryOfLatestCWithoutAnotherApplication() throws {
        let b = try layout(mainExternal: true)
        let c = try layout(distance: -1920)
        var record = try ownedRecord()
        try record.observe(c, source: .confirmedUser)
        XCTAssertFalse(record.layoutPending)

        try record.observe(b, source: .reconnect)
        XCTAssertEqual(record.baseline, c)
        XCTAssertEqual(record.generation, 1)
        XCTAssertTrue(record.layoutPending)
        let plan = try record.layoutRestorePlan(connected: [
            ConnectedDisplay(identity: internalID, numericID: 80),
            ConnectedDisplay(identity: externalID, numericID: 40)
        ], current: b)
        XCTAssertEqual(plan.origins[80], c.origins[internalID])
        XCTAssertEqual(plan.origins[40], c.origins[externalID])
        record.beginRestoration()
        try record.confirmRestored(actual: c)
        XCTAssertTrue(record.canClear)
    }

    func testKnownBReturningAfterUnresolvedDDoesNotEraseSourceUncertainty() throws {
        let b = try layout(mainExternal: true)
        let c = try layout(distance: -1920)
        var record = try ownedRecord()
        try record.observe(c, source: .confirmedUser)
        XCTAssertThrowsError(try record.observe(layout(distance: 2000), source: .unknown))

        try record.observe(b, source: .reconnect)
        XCTAssertEqual(record.baseline, c)
        XCTAssertTrue(record.layoutPending)
        XCTAssertTrue(record.sourceUnresolved)
        XCTAssertThrowsError(try record.prepareReapplication(current: b, target: b))
        XCTAssertThrowsError(try record.layoutRestorePlan(connected: [], current: b))
    }

    func testReconnectedDisabledBitRearmsRecoveryOfUserEnabledC() throws {
        var record = try ownedRecord(internalDisplay: InternalDisplayResponsibility(
            identity: internalID, baseline: true, applied: false
        ))
        try record.observeInternalEnabled(true, source: .confirmedUser)
        XCTAssertFalse(record.internalDisplay?.pending == true)

        try record.observeInternalEnabled(false, source: .reconnect)
        XCTAssertTrue(record.internalDisplay?.pending == true)
        let plan = try record.internalRestorePlan(connected: [
            ConnectedDisplay(identity: internalID, numericID: 80)
        ])
        XCTAssertEqual(plan?.id, 80)
        XCTAssertEqual(plan?.enabled, true)
    }

    func testUncoveredInternalCStillRequiresActualEnabledReadback() throws {
        var record = try ownedRecord(internalDisplay: InternalDisplayResponsibility(
            identity: internalID, baseline: true, applied: false
        ))
        try record.observeInternalEnabled(true, source: .confirmedUser)
        record.beginRestoration()
        XCTAssertThrowsError(try record.confirmRestored(actual: layout(), internalEnabled: false))
        XCTAssertFalse(record.canClear)
        try record.confirmRestored(actual: layout(), internalEnabled: true)
        XCTAssertTrue(record.canClear)
    }

    func testUnconfirmedConfigurationStopsNewControl() throws {
        var record = try ownedRecord()
        let c = try layout(distance: -1920)
        XCTAssertThrowsError(try record.observe(c, source: .unknown))
        XCTAssertEqual(record.baseline, try layout())
        XCTAssertTrue(record.sourceUnresolved)
        XCTAssertThrowsError(try record.prepareReapplication(current: c, target: layout(mainExternal: true)))
        XCTAssertThrowsError(try record.layoutRestorePlan(connected: [], current: c))
        XCTAssertFalse(record.canClear)
    }

    func testMissingDisplayObservationKeepsFullConfirmedC() throws {
        let c = try layout(distance: -1920)
        var record = try ownedRecord()
        try record.observe(c, source: .confirmedUser)
        let partial = try DisplayLayout(main: internalID, origins: [internalID: DisplayOrigin(x: 0, y: 0)])

        XCTAssertNoThrow(try record.observe(partial, source: .reconnect))
        XCTAssertEqual(record.baseline, c)
        XCTAssertFalse(record.sourceUnresolved)
        XCTAssertFalse(record.layoutPending)
        XCTAssertFalse(record.canClear)
    }

    func testPartialTopologyCannotBeConfirmedAsFullUserC() throws {
        let c = try layout(distance: -1920)
        var record = try ownedRecord()
        try record.observe(c, source: .confirmedUser)
        let partial = try DisplayLayout(main: internalID, origins: [internalID: DisplayOrigin(x: 0, y: 0)])

        XCTAssertThrowsError(try record.observe(partial, source: .confirmedUser))
        XCTAssertEqual(record.baseline, c)
        XCTAssertTrue(record.sourceUnresolved)
        XCTAssertFalse(record.canClear)
    }

    func testForeignDisplayTopologyDoesNotMasqueradeAsMissingTarget() throws {
        var record = try ownedRecord()
        let foreign = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0), otherID: DisplayOrigin(x: 1728, y: 0)
        ])
        XCTAssertThrowsError(try record.observe(foreign, source: .reconnect))
        XCTAssertEqual(record.baseline, try layout())
        XCTAssertTrue(record.sourceUnresolved)
        XCTAssertThrowsError(try record.prepareReapplication(current: record.applied, target: record.applied))
    }

    func testInFlightCallbackCannotBecomeUserBaseline() throws {
        var record = try RecoveryRecord(baseline: layout(), target: layout(mainExternal: true))
        try record.markApplying()
        try record.observe(layout(distance: -1920), source: .confirmedUser)
        XCTAssertEqual(record.baseline, try layout())
        XCTAssertTrue(record.sourceUnresolved)
        XCTAssertFalse(record.canClear)
    }

    func testMissingTargetRestoresOnlyApplicableDisplayAndKeepsResponsibility() throws {
        var record = try RecoveryRecord(baseline: layout(mainExternal: true), target: layout())
        try record.confirmApplied(layout())
        record.beginRestoration()
        let partial = try DisplayLayout(main: internalID, origins: [internalID: DisplayOrigin(x: 0, y: 0)])
        let plan = try record.layoutRestorePlan(connected: [ConnectedDisplay(identity: internalID, numericID: 80)], current: partial)
        XCTAssertEqual(plan.origins, [80: DisplayOrigin(x: 0, y: 0)])
        XCTAssertEqual(plan.missing, [externalID])
        XCTAssertThrowsError(try record.confirmRestored(actual: partial))
        XCTAssertTrue(record.layoutPending)
        XCTAssertFalse(record.canClear)
    }

    func testOldNumericIDIsNotAppliedToDifferentIdentity() throws {
        let record = try ownedRecord()
        let unrelated = try DisplayLayout(main: internalID, origins: [internalID: DisplayOrigin(x: 0, y: 0), otherID: DisplayOrigin(x: 1728, y: 0)])
        XCTAssertThrowsError(try record.layoutRestorePlan(connected: [
            ConnectedDisplay(identity: internalID, numericID: 80),
            ConnectedDisplay(identity: otherID, numericID: 40)
        ], current: unrelated))
    }

    func testConflictingIdentityOrNumericIDIsRejected() throws {
        let record = try ownedRecord()
        XCTAssertThrowsError(try record.layoutRestorePlan(connected: [
            ConnectedDisplay(identity: internalID, numericID: 80),
            ConnectedDisplay(identity: internalID, numericID: 40)
        ], current: layout(mainExternal: true)))
        XCTAssertThrowsError(try record.layoutRestorePlan(connected: [
            ConnectedDisplay(identity: internalID, numericID: 80),
            ConnectedDisplay(identity: externalID, numericID: 80)
        ], current: layout(mainExternal: true)))
        XCTAssertThrowsError(try record.layoutRestorePlan(connected: [ConnectedDisplay(identity: internalID, numericID: 0)], current: layout(mainExternal: true)))
    }

    func testInternalResponsibilitySurvivesIncompleteRestoration() throws {
        let responsibility = InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false)
        var record = try ownedRecord(internalDisplay: responsibility)
        record.beginRestoration()
        XCTAssertThrowsError(try record.confirmRestored(actual: layout(), internalEnabled: false))
        XCTAssertFalse(record.layoutPending)
        XCTAssertTrue(record.internalDisplay?.pending == true)
        XCTAssertFalse(record.canClear)
        try record.confirmRestored(actual: layout(), internalEnabled: true)
        XCTAssertTrue(record.canClear)
    }

    func testUncertainLayoutDoesNotRemoveInternalSafetyPlan() throws {
        let responsibility = InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false)
        var record = try ownedRecord(internalDisplay: responsibility)
        XCTAssertThrowsError(try record.observe(layout(distance: -1920), source: .unknown))
        let plan = try record.internalRestorePlan(connected: [ConnectedDisplay(identity: internalID, numericID: 99)])
        XCTAssertEqual(plan?.id, 99)
        XCTAssertEqual(plan?.enabled, true)
        XCTAssertTrue(record.requiresRecovery)
    }

    func testRecoveryAndOwnReadbacksNeverPromoteApplicationBaseline() throws {
        var record = try ownedRecord()
        record.beginRestoration()
        try record.observe(layout(mainExternal: true), source: .ownCallback)
        XCTAssertEqual(record.baseline, try layout())
        try record.confirmRestored(actual: layout())
        XCTAssertEqual(record.baseline, try layout())
    }

    func testStaleRecordCannotOverwriteUnobservedC() throws {
        let record = try ownedRecord()
        XCTAssertThrowsError(try record.layoutRestorePlan(connected: [
            ConnectedDisplay(identity: internalID, numericID: 80),
            ConnectedDisplay(identity: externalID, numericID: 40)
        ], current: layout(distance: -1920)))
        XCTAssertFalse(record.canClear)
    }

    func testInvalidLayoutAndDecodedVersionAreRejected() throws {
        XCTAssertThrowsError(try DisplayLayout(main: internalID, origins: [:]))
        let record = try ownedRecord()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["version"] = 99
        let decoded = try JSONDecoder().decode(RecoveryRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try decoded.validate())
    }

    func testUnknownChangeAfterCDoesNotClearUnresolvedSource() throws {
        var record = try ownedRecord()
        try record.observe(layout(distance: -1920), source: .confirmedUser)
        let d = try layout(distance: 2000)
        XCTAssertThrowsError(try record.observe(d, source: .unknown))
        record.beginRestoration()
        XCTAssertThrowsError(try record.confirmRestored(actual: d))
        XCTAssertTrue(record.sourceUnresolved)
        XCTAssertFalse(record.canClear)
    }

    func testUncertainApplyingRecordRequiresFullBaselineForConfirmation() throws {
        var record = try ownedRecord()
        try record.prepareReapplication(current: record.applied, target: record.applied)
        try record.markApplying()
        try record.observe(layout(distance: 2000), source: .unknown)
        XCTAssertTrue(record.sourceUnresolved)
        let session = record.session
        let generation = record.generation
        XCTAssertEqual(generation, 2)
        record.beginRestoration()
        let partial = try DisplayLayout(main: internalID, origins: [internalID: DisplayOrigin(x: 0, y: 0)])
        XCTAssertThrowsError(try record.confirmRestored(actual: partial))
        XCTAssertThrowsError(try record.confirmRestored(actual: layout(distance: 2000)))
        XCTAssertThrowsError(try record.confirmRestored(actual: layout(mainExternal: true)))
        XCTAssertTrue(record.sourceUnresolved)
        XCTAssertTrue(record.layoutPending)
        try record.confirmRestored(actual: layout())
        XCTAssertTrue(record.canClear)
        XCTAssertEqual(record.session, session)
        XCTAssertEqual(record.generation, generation)
        XCTAssertEqual(record.baseline, try layout())
    }

    func testUnobservedDDoesNotMasqueradeAsDirectCExit() throws {
        var record = try ownedRecord()
        try record.observe(layout(distance: -1920), source: .confirmedUser)
        XCTAssertThrowsError(try record.layoutRestorePlan(connected: [], current: layout(distance: 2000)))
        XCTAssertFalse(record.canClear)
    }

    func testDecodedPreparedRecordCannotDropPendingLayout() throws {
        let record = try RecoveryRecord(baseline: layout(), target: layout(mainExternal: true))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["layoutPending"] = false
        let decoded = try JSONDecoder().decode(RecoveryRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try decoded.validate())
    }

    func testReconnectToKnownAAllowsReapplicationWithoutPromotingNewBaseline() throws {
        var record = try ownedRecord()
        let a = try layout()
        try record.observe(a, source: .reconnect)
        XCTAssertEqual(record.baseline, a)
        XCTAssertFalse(record.layoutPending)
        try record.prepareReapplication(current: a, target: layout(mainExternal: true))
        XCTAssertEqual(record.generation, 2)
        XCTAssertEqual(record.baseline, a)
        XCTAssertTrue(record.layoutPending)
    }

    func testReconnectADoesNotEraseEarlierUnknownSource() throws {
        var record = try ownedRecord()
        XCTAssertThrowsError(try record.observe(layout(distance: -1920), source: .unknown))
        XCTAssertThrowsError(try record.observe(layout(), source: .reconnect))
        XCTAssertTrue(record.sourceUnresolved)
        XCTAssertTrue(record.layoutPending)
    }

    func testUserAStillRequiresExplicitSourceConfirmation() throws {
        var record = try ownedRecord()
        XCTAssertThrowsError(try record.observe(layout(), source: .unknown))
        XCTAssertTrue(record.sourceUnresolved)
        try record.observe(layout(), source: .confirmedUser)
        XCTAssertFalse(record.sourceUnresolved)
        XCTAssertFalse(record.layoutPending)
    }

    func testPersistedUnknownSourceCanBeConfirmedAfterExclusiveRestart() throws {
        var record = try ownedRecord()
        let c = try layout(distance: -1920)
        XCTAssertThrowsError(try record.observe(c, source: .unknown))
        var restarted = try JSONDecoder().decode(RecoveryRecord.self, from: JSONEncoder().encode(record))
        try restarted.validate()
        try restarted.observe(c, source: .confirmedUser)
        XCTAssertEqual(restarted.baseline, c)
        XCTAssertFalse(restarted.sourceUnresolved)
        XCTAssertFalse(restarted.layoutPending)
        restarted.beginRestoration()
        try restarted.confirmRestored(actual: c)
        XCTAssertTrue(restarted.canClear)
    }
}
