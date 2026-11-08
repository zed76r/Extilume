import CoreGraphics
import Darwin
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class GuardRecoveryTests: XCTestCase {
    private let internalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let externalID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let otherID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    private let session = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let otherSession = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

    private enum FixtureError: Error { case injected }

    func testTopologyCountsAndLayoutRelationshipsDistinguishRecoveryFixtures() throws {
        let record = try confirmedCRecord()
        let c = record.baseline
        let b = try externalOnlyLayout()
        let unknownLayout = try layout(mainExternal: true, internalX: -1900)
        let full = snapshot(c)
        let knownB = snapshot(b, internalActive: false)
        let missingInternal = Snapshot(displays: [makeDisplay(id: 40, identity: .physical, uuid: externalID, layout: b)])
        let missingExternal = snapshot(c, includeExternal: false)
        let unknownIdentity = Snapshot(displays: [makeDisplay(id: 40, identity: .unknown, uuid: externalID, layout: b)])
        let unknown = snapshot(unknownLayout)

        let fullCounts = InternalRecoveryTopologyContext(snapshot: full)
        XCTAssertEqual(fullCounts.onlineDisplayCount, 2)
        XCTAssertEqual(fullCounts.activeDisplayCount, 2)
        XCTAssertEqual(fullCounts.activeBuiltInCount, 1)
        XCTAssertEqual(fullCounts.activePhysicalCount, 1)
        XCTAssertEqual(fullCounts.activeOtherCount, 0)
        let marker = try internalLifecycleMarker(.recoveryTopologyObserved, at: 1, mainThread: false,
                                                 recoveryTopology: fullCounts)
        XCTAssertFalse(marker.contains(internalID.uuidString))
        XCTAssertFalse(marker.contains(externalID.uuidString))
        XCTAssertFalse(marker.contains("registryEntryID"))
        XCTAssertFalse(marker.contains("EDID"))
        XCTAssertTrue(InternalRecoveryLayoutContext(record: record, current: try full.layout()).matchesBaseline)
        let bCounts = InternalRecoveryTopologyContext(snapshot: knownB)
        XCTAssertEqual(bCounts.onlineDisplayCount, 2)
        XCTAssertEqual(bCounts.activeBuiltInCount, 0)
        XCTAssertEqual(bCounts.activePhysicalCount, 1)
        XCTAssertTrue(InternalRecoveryLayoutContext(record: record, current: try knownB.layout()).matchesApplied)
        let missingInternalCounts = InternalRecoveryTopologyContext(snapshot: missingInternal)
        XCTAssertEqual(missingInternalCounts.onlineDisplayCount, 1)
        XCTAssertEqual(missingInternalCounts.activeBuiltInCount, 0)
        XCTAssertEqual(missingInternalCounts.activePhysicalCount, 1)
        XCTAssertTrue(InternalRecoveryLayoutContext(record: record, current: try missingInternal.layout()).matchesApplied)
        let missingExternalCounts = InternalRecoveryTopologyContext(snapshot: missingExternal)
        XCTAssertEqual(missingExternalCounts.activeBuiltInCount, 1)
        XCTAssertEqual(missingExternalCounts.activePhysicalCount, 0)
        let missingExternalLayout = InternalRecoveryLayoutContext(record: record, current: try missingExternal.layout())
        XCTAssertTrue(missingExternalLayout.isBaselineDisplaySubset)
        XCTAssertFalse(missingExternalLayout.matchesBaseline)
        XCTAssertFalse(missingExternalLayout.matchesApplied)
        XCTAssertFalse(missingExternalLayout.matchesPreDisable)
        XCTAssertFalse(missingExternalLayout.matchesBaselineDisplaySet)
        XCTAssertFalse(missingExternalLayout.layoutPending)
        XCTAssertEqual(missingExternalLayout.internalPending, false)
        XCTAssertFalse(missingExternalLayout.sourceUnresolved)
        let otherCounts = InternalRecoveryTopologyContext(snapshot: unknownIdentity)
        XCTAssertEqual(otherCounts.activeOtherCount, 1)
        XCTAssertEqual(otherCounts.activePhysicalCount, 0)
        let unknownRelationship = InternalRecoveryLayoutContext(record: record, current: try unknown.layout())
        XCTAssertFalse(unknownRelationship.matchesBaseline)
        XCTAssertFalse(unknownRelationship.matchesApplied)
        XCTAssertFalse(unknownRelationship.matchesPreDisable)
        XCTAssertEqual(InternalRecoveryTopologyContext(snapshot: unknown), fullCounts)
    }

    func testEmptySnapshotIsObservedBeforeLayoutRejectsWithoutDisplayWrites() throws {
        let baseline = try layout()
        let record = try applyingRecord(baseline: baseline, target: baseline, includesInternal: false)
        try withStore { store, _ in
            try store.save(record)
            var observed: [InternalRecoveryTopologyContext] = []
            XCTAssertThrowsError(try recoverGuardRecord(
                store: store, contract: contract(for: record),
                snapshotReader: { Snapshot(displays: []) },
                internalReader: { _ in XCTFail("unexpected internal read"); throw FixtureError.injected },
                enableInternal: { _ in XCTFail("empty snapshot cannot enable") },
                originWriter: { _, _ in XCTFail("empty snapshot cannot write origins") },
                topologyObserved: { observed.append($0) }
            ))
            XCTAssertEqual(observed, [InternalRecoveryTopologyContext(snapshot: Snapshot(displays: []))])
            XCTAssertFalse(try XCTUnwrap(store.load()).canClear)
        }
    }

    func testSleepingRecoveryLeavesResponsibilityAndDoesNotReadOrWriteDisplays() throws {
        let record = try applyingRecord()
        let gate = InternalPowerGate()
        gate.didRegister()
        gate.willSleep()
        gate.didAcknowledgeSleep(true)
        try withStore { store, _ in
            try store.save(record)
            XCTAssertThrowsError(try recoverGuardRecord(
                store: store, contract: contract(for: record),
                snapshotReader: { XCTFail("sleep cannot query displays"); throw FixtureError.injected },
                internalReader: { _ in XCTFail("sleep cannot query internal"); throw FixtureError.injected },
                enableInternal: { _ in XCTFail("sleep cannot enable") },
                originWriter: { _, _ in XCTFail("sleep cannot change layout") },
                checkAccess: { try gate.check() }
            ))
            XCTAssertEqual(try store.load(), record)
            XCTAssertFalse(record.canClear)
        }
    }

    func testSleepDuringEnableKeepsPendingRecordAndWakeRestoresOriginalC() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)
        let gate = InternalPowerGate()
        gate.didRegister()
        var enabled = false
        var actual = target
        var events: [String] = []
        try withStore { store, _ in
            try store.save(record)
            func recover() throws -> RecoveryRecord {
                try recoverGuardRecord(
                    store: store, contract: contract(for: record),
                    snapshotReader: { self.snapshot(actual, internalActive: enabled) },
                    internalReader: { identity in try self.snapshot(actual, internalActive: enabled).internalDisplayState(identity: identity) },
                    enableInternal: { _ in
                        events.append("enable")
                        enabled = true
                        gate.willSleep()
                    },
                    originWriter: { _, _ in events.append("origins"); actual = baseline },
                    checkAccess: { try gate.check() }
                )
            }
            XCTAssertThrowsError(try recover())
            XCTAssertEqual(events, ["enable"])
            XCTAssertEqual(try store.load()?.phase, .restoring)
            XCTAssertEqual(try store.load()?.baseline, baseline)
            XCTAssertFalse(try XCTUnwrap(store.load()).canClear)
            gate.didAcknowledgeSleep(true)
            gate.didWake()
            let restored = try recover()
            XCTAssertEqual(events, ["enable", "origins"])
            XCTAssertEqual(restored.phase, .restored)
            XCTAssertEqual(restored.baseline, baseline)
            XCTAssertEqual(actual, baseline)
        }
    }

    func testFailedLayoutReadLeavesStageOpenAndRecoveryResponsibilityPending() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)
        try withStore { store, _ in
            try store.save(record)
            var enabled = false
            var stages: [InternalLifecycleStage] = []
            XCTAssertThrowsError(try recoverGuardRecord(
                store: store, contract: contract(for: record),
                snapshotReader: { throw FixtureError.injected },
                internalReader: { identity in
                    try self.snapshot(target, internalActive: enabled).internalDisplayState(identity: identity)
                },
                enableInternal: { _ in enabled = true },
                originWriter: { _, _ in XCTFail("failed snapshot cannot authorize origins") },
                trace: { stages.append($0) }
            ))
            XCTAssertTrue(stages.contains(.enableFinished))
            XCTAssertEqual(stages.last, .layoutReadStarted)
            XCTAssertFalse(stages.contains(.restorationVerified))
            XCTAssertEqual(try store.load()?.phase, .restoring)
            XCTAssertFalse(try XCTUnwrap(store.load()).canClear)
        }
    }

    func testInternalRecoveryRetriesHaveBoundedDelayAndThenWaitForEvents() throws {
        XCTAssertEqual(internalRecoveryRetryDelay(attemptCount: 0, elapsed: 0), 0.1)
        XCTAssertEqual(internalRecoveryRetryDelay(attemptCount: 1, elapsed: 0), 0.2)
        XCTAssertEqual(internalRecoveryRetryDelay(attemptCount: Int.max, elapsed: 0), 1)
        XCTAssertEqual(internalRecoveryRetryDelay(attemptCount: 9, elapsed: 9_900_000_000), 0.1)
        XCTAssertNil(internalRecoveryRetryDelay(attemptCount: 1, elapsed: 10_000_000_000))
        XCTAssertNil(internalRecoveryRetryDelay(attemptCount: 1, elapsed: UInt64.max))
        XCTAssertNil(internalRecoveryRetryDelay(attemptCount: 1, elapsed: nil))
    }

    func testUnchangedLayoutIsRecordedRestoredWithoutWritingOrigins() throws {
        let baseline = try layout()
        let record = try applyingRecord(baseline: baseline, target: baseline, includesInternal: false)

        try withStore { store, _ in
            try store.save(record)
            var writes = 0
            let restored = try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: { self.snapshot(baseline) },
                internalReader: { _ in throw FixtureError.injected },
                enableInternal: { _ in XCTFail("unexpected internal enable") },
                originWriter: { _, _ in writes += 1 }
            )

            XCTAssertEqual(writes, 0)
            XCTAssertTrue(restored.canClear)
            XCTAssertEqual(restored.phase, .restored)
            XCTAssertEqual(try store.load(), restored)
        }
    }

    func testAlreadyEnabledInternalDisplaySkipsEnableAndRestoresRecord() throws {
        let baseline = try layout(mainExternal: true)
        let record = try ownedRecord(baseline: baseline, target: baseline)

        try withStore { store, _ in
            try store.save(record)
            var enables = 0
            var writes = 0
            let restored = try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: { self.snapshot(baseline, internalActive: true) },
                internalReader: { identity in
                    try self.snapshot(baseline, internalActive: true).internalDisplayState(identity: identity)
                },
                enableInternal: { _ in enables += 1 },
                originWriter: { _, _ in writes += 1 }
            )

            XCTAssertEqual(enables, 0)
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(restored.phase, .restored)
            XCTAssertFalse(try XCTUnwrap(restored.internalDisplay).pending)
            XCTAssertEqual(try store.load(), restored)
        }
    }

    func testExactKnownBReappearingAfterConfirmedCRearmsBeforeEnablingAndRestoresC() throws {
        let record = try confirmedCRecord()
        let c = record.baseline
        var current = snapshot(try externalOnlyLayout(), internalActive: false)
        var events: [String] = []
        try withStore { store, _ in
            try store.save(record)
            let restored = try recoverGuardRecord(
                store: store, contract: contract(for: record),
                snapshotReader: { current },
                internalReader: { _ in self.provenInternal(record, active: current.displays[0].isActive) },
                enableInternal: { restoring in
                    XCTAssertEqual(try store.load(), restoring)
                    XCTAssertTrue(restoring.layoutPending)
                    XCTAssertTrue(try XCTUnwrap(restoring.internalDisplay).pending)
                    XCTAssertEqual(restoring.baseline, c)
                    events.append("enable")
                    current = self.snapshot(try XCTUnwrap(record.preDisableLayout))
                },
                originWriter: { restoring, origins in
                    XCTAssertEqual(try store.load(), restoring)
                    XCTAssertTrue(restoring.internalDisplay?.pending == true)
                    XCTAssertEqual(origins, [80: DisplayOrigin(x: 0, y: 0), 40: DisplayOrigin(x: 1728, y: 0)])
                    events.append("origins")
                    current = self.snapshot(c)
                }
            )
            XCTAssertEqual(events, ["enable", "origins"])
            XCTAssertEqual(restored.baseline, c)
            XCTAssertEqual(restored.session, record.session)
            XCTAssertEqual(restored.generation, record.generation)
            XCTAssertTrue(restored.canClear)
            XCTAssertEqual(try store.load(), restored)
        }
    }

    func testWakeTopologyWaitRequiresExactConfirmedCAndEnabledInternal() throws {
        let record = try confirmedCRecord()
        let full = snapshot(record.baseline)
        let anchor = try InternalWakeTopologyReadiness(record: record, snapshot: full)
        let state = provenInternal(record, active: true)
        XCTAssertTrue(try anchor.isWaiting(current: snapshot(record.baseline, includeExternal: false),
                                          internalState: state, record: record))
        XCTAssertFalse(try anchor.isWaiting(current: full, internalState: state, record: record))
        XCTAssertThrowsError(try anchor.isWaiting(current: snapshot(record.baseline, includeExternal: false),
                                                  internalState: provenInternal(record, active: false), record: record))
        XCTAssertThrowsError(try anchor.isWaiting(current: Snapshot(displays: []), internalState: state, record: record))
        XCTAssertThrowsError(try anchor.isWaiting(current: snapshot(try layout(mainExternal: true)),
                                                  internalState: state, record: record))
        XCTAssertThrowsError(try anchor.isWaiting(current: snapshot(record.baseline, internalActive: false),
                                                  internalState: state, record: record))
        for key in ["id", "originX", "rotation", "mode"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
            var displays = try XCTUnwrap(object["displays"] as? [[String: Any]])
            if key == "mode" {
                var mode = try XCTUnwrap(displays[1]["mode"] as? [String: Any])
                mode["refreshRate"] = 30
                displays[1]["mode"] = mode
            } else {
                displays[0][key] = 999
            }
            object["displays"] = displays
            let different = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try anchor.isWaiting(current: different, internalState: state, record: record), key)
        }
        var changed = record
        changed.beginRestoration()
        XCTAssertThrowsError(try anchor.isWaiting(current: full, internalState: state, record: changed))
        XCTAssertThrowsError(try InternalWakeTopologyReadiness(record: applyingRecord(), snapshot: full))
        XCTAssertThrowsError(try InternalWakeTopologyReadiness(record: confirmedCRecord(hardware: false), snapshot: full))
        XCTAssertThrowsError(try InternalWakeTopologyReadiness(record: record,
                                                               snapshot: snapshot(record.baseline, includeExternal: false)))
    }

    func testNormalWakeReapplicationRejectsChangedConfigurationAndSleepEpoch() throws {
        let record = try confirmedCRecord()
        let full = snapshot(record.baseline)
        let epoch = UUID()
        let readiness = InternalNormalWakeReapplication(epoch: epoch,
            topology: try InternalWakeTopologyReadiness(record: record, snapshot: full), verifiedAt: 30_000_000_000)
        XCTAssertNoThrow(try readiness.verify(current: full, record: record, epoch: epoch))
        XCTAssertThrowsError(try readiness.verify(current: full, record: record, epoch: UUID()))
        for changed in [snapshot(record.baseline, includeExternal: false),
                        snapshot(record.baseline, internalActive: false), snapshot(try layout(mainExternal: true))] {
            XCTAssertThrowsError(try readiness.verify(current: changed, record: record, epoch: epoch))
        }
        let prepared = try prepareProtectedInternalReapplication(record: record, snapshot: full)
        XCTAssertNoThrow(try readiness.verifyPrepared(prepared, epoch: epoch))
        XCTAssertThrowsError(try readiness.verifyPrepared(prepared, epoch: UUID()))
        XCTAssertThrowsError(try readiness.verifyPrepared(record, epoch: epoch))
        XCTAssertThrowsError(try readiness.verify(current: full, record: prepared, epoch: epoch))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(full)) as? [String: Any])
        var displays = try XCTUnwrap(object["displays"] as? [[String: Any]])
        var mode = try XCTUnwrap(displays[1]["mode"] as? [String: Any])
        mode["refreshRate"] = 30
        displays[1]["mode"] = mode
        object["displays"] = displays
        let changedMode = try JSONDecoder().decode(Snapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try readiness.verify(current: changedMode, record: record, epoch: epoch))
    }

    func testWakeTopologyWaitUsesOriginalDeadlineAndRejectsFaultOrStop() {
        var state = InternalSessionLifecycle()
        XCTAssertTrue(state.willSleep())
        state.finishSleepPreparation(acknowledged: true)
        state.didWake()
        let error = GuardError.externalTopologyPending
        XCTAssertEqual(internalWakeInformationRetryDelay(error: error, elapsed: 0, lifecycle: state), 0.3)
        XCTAssertEqual(internalWakeInformationRetryDelay(error: error, elapsed: 9_900_000_000, lifecycle: state), 0.1)
        XCTAssertNil(internalWakeInformationRetryDelay(error: error, elapsed: 10_000_000_000, lifecycle: state))
        XCTAssertNil(internalWakeInformationRetryDelay(error: error, elapsed: nil, lifecycle: state))
        var paused = state
        paused.requestPause()
        XCTAssertNil(internalWakeInformationRetryDelay(error: error, elapsed: 0, lifecycle: paused))
        var stopped = state
        stopped.requestStop()
        XCTAssertNil(internalWakeInformationRetryDelay(error: error, elapsed: 0, lifecycle: stopped))
        state.fail()
        XCTAssertNil(internalWakeInformationRetryDelay(error: error, elapsed: 0, lifecycle: state))
    }

    func testTransientMissingExternalRetainsRecordUntilExactCReturnsWithoutDisplayWrites() throws {
        let record = try confirmedCRecord()
        var externalPresent = false
        var lifecycle = InternalSessionLifecycle()
        XCTAssertTrue(lifecycle.willSleep())
        lifecycle.finishSleepPreparation(acknowledged: true)
        lifecycle.didWake()
        try withStore { store, directory in
            try store.save(record)
            let path = directory.appendingPathComponent("recovery-record.json")
            let before = try Data(contentsOf: path)
            func recover() throws -> RecoveryRecord {
                try recoverGuardRecord(
                    store: store, contract: contract(for: record),
                    snapshotReader: { self.snapshot(record.baseline, includeExternal: externalPresent) },
                    internalReader: { _ in self.provenInternal(record, active: true) },
                    enableInternal: { _ in XCTFail("already enabled internal must not be written") },
                    originWriter: { _, _ in XCTFail("missing external or exact C must not write origins") }
                )
            }
            XCTAssertThrowsError(try recover()) { error in
                XCTAssertEqual(error as? RecoveryError, .unresolvedSource)
                XCTAssertNil(internalWakeVerificationRetryDelay(error: error, attempt: 0, lifecycle: lifecycle))
            }
            XCTAssertEqual(try Data(contentsOf: path), before)
            XCTAssertEqual(try store.load(), record)
            XCTAssertTrue(lifecycle.wakeRecoveryRequired)
            XCTAssertFalse(lifecycle.permitsControls)
            externalPresent = true
            let restored = try recover()
            XCTAssertTrue(restored.canClear)
            XCTAssertEqual(restored.baseline, record.baseline)
            XCTAssertEqual(restored.session, record.session)
            XCTAssertEqual(restored.generation, record.generation)
            XCTAssertEqual(try store.load(), restored)
        }
    }

    func testRejectedSubsetPreservesLaterExactBRecoveryAfterOwnershipHandoff() throws {
        let record = try confirmedCRecord()
        var actual = record.baseline
        var enabled = true
        var externalPresent = false
        var events: [String] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("extilume-recovery-handoff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        var owner: RecoveryStore? = try RecoveryStore(directory: directory)
        try XCTUnwrap(owner).acquireExclusiveOwnership()
        try XCTUnwrap(owner).save(record)
        func recover(using store: RecoveryStore) throws -> RecoveryRecord {
            try recoverGuardRecord(
                store: store, contract: contract(for: record),
                snapshotReader: { self.snapshot(actual, internalActive: enabled, includeExternal: externalPresent) },
                internalReader: { _ in self.provenInternal(record, active: enabled) },
                enableInternal: { _ in
                    events.append("enable")
                    enabled = true
                    actual = try XCTUnwrap(record.preDisableLayout)
                },
                originWriter: { restoring, _ in
                    events.append("origins")
                    XCTAssertEqual(restoring.baseline, record.baseline)
                    actual = restoring.baseline
                }
            )
        }
        XCTAssertThrowsError(try recover(using: XCTUnwrap(owner)))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(try XCTUnwrap(owner).load(), record)
        let helper = try RecoveryStore(directory: directory)
        XCTAssertThrowsError(try helper.acquireExclusiveOwnership())
        owner = nil
        try helper.acquireExclusiveOwnership()
        XCTAssertEqual(try helper.load(), record)
        actual = try externalOnlyLayout()
        enabled = false
        externalPresent = true
        let restored = try recover(using: helper)
        XCTAssertEqual(events, ["enable", "origins"])
        XCTAssertEqual(restored.baseline, record.baseline)
        XCTAssertEqual(restored.session, record.session)
        XCTAssertEqual(restored.generation, record.generation)
        XCTAssertTrue(restored.canClear)
        XCTAssertEqual(try helper.load(), restored)
    }

    func testLateEnableAcrossWakeAndIndependentAcknowledgementsRetainsHandoffResponsibility() throws {
        for fails in [false, true] {
            let record = try confirmedCRecord()
            let ownerGate = InternalPowerGate()
            let helperGate = InternalPowerGate()
            ownerGate.didRegister()
            helperGate.didRegister()
            var lifecycle = InternalSessionLifecycle()
            var actual = try externalOnlyLayout()
            var enabled = false
            var calls = 0
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("extilume-interleaving-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            var owner: RecoveryStore? = try RecoveryStore(directory: directory)
            try XCTUnwrap(owner).acquireExclusiveOwnership()
            try XCTUnwrap(owner).save(record)
            let helper = try RecoveryStore(directory: directory)

            func recover(using store: RecoveryStore, gate: InternalPowerGate, enable: (RecoveryRecord) throws -> Void) throws -> RecoveryRecord {
                try recoverGuardRecord(
                    store: store, contract: contract(for: record),
                    snapshotReader: { self.snapshot(actual, internalActive: enabled) },
                    internalReader: { _ in self.provenInternal(record, active: enabled) },
                    enableInternal: enable,
                    originWriter: { restoring, _ in actual = restoring.baseline },
                    checkAccess: { try gate.check() }
                )
            }

            XCTAssertThrowsError(try recover(using: XCTUnwrap(owner), gate: ownerGate) { _ in
                try ownerGate.perform {
                    calls += 1
                    XCTAssertTrue(ownerGate.willSleep())
                    XCTAssertTrue(helperGate.willSleep())
                    XCTAssertTrue(lifecycle.willSleep())
                    if fails { lifecycle.requestPause() } else { lifecycle.requestStop() }
                    XCTAssertTrue(ownerGate.didWake())
                    XCTAssertTrue(helperGate.didWake())
                    lifecycle.didWake()
                    XCTAssertFalse(lifecycle.permitsRecovery)
                    if fails { throw FixtureError.injected }
                    enabled = true
                    actual = try XCTUnwrap(record.preDisableLayout)
                }
            }) { error in
                if fails {
                    XCTAssertTrue(error is FixtureError)
                } else {
                    XCTAssertEqual(error as? InternalPowerGateError, .suspended)
                }
            }
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(enabled, !fails)
            XCTAssertEqual(try XCTUnwrap(owner).load()?.phase, .restoring)
            XCTAssertThrowsError(try helper.acquireExclusiveOwnership()) {
                XCTAssertEqual($0 as? RecoveryStoreError, .ownershipUnavailable)
            }
            ownerGate.didAcknowledgeSleep(true)
            lifecycle.finishSleepPreparation(acknowledged: true)
            XCTAssertTrue(lifecycle.shouldRecoverAfterWake)
            XCTAssertFalse(lifecycle.shouldResumeAfterWake)
            XCTAssertThrowsError(try helperGate.check())
            owner = nil
            try helper.acquireExclusiveOwnership()
            XCTAssertThrowsError(try recover(using: helper, gate: helperGate) { _ in XCTFail("unacknowledged helper cannot enable") })
            helperGate.didAcknowledgeSleep(true)
            let restored = try recover(using: helper, gate: helperGate) { _ in
                calls += 1
                enabled = true
                actual = try XCTUnwrap(record.preDisableLayout)
            }
            lifecycle.didRestore()
            XCTAssertFalse(lifecycle.shouldResumeAfterWake)
            XCTAssertEqual(calls, fails ? 2 : 1)
            XCTAssertEqual(restored.baseline, record.baseline)
            XCTAssertEqual(restored.session, record.session)
            XCTAssertEqual(restored.generation, record.generation)
            XCTAssertEqual(actual, record.baseline)
            XCTAssertEqual(try helper.load(), restored)
            XCTAssertTrue(restored.canClear)
        }
    }

    func testConfirmedCDoesNotRearmForUnprovenOrUnknownReappearance() throws {
        for scenario in ["unknown", "pre-disable", "no-hardware", "wrong-hardware", "enabled", "restored", "unresolved"] {
            var record = try confirmedCRecord(hardware: scenario != "no-hardware")
            if scenario == "restored" {
                record.beginRestoration()
                try record.confirmRestored(actual: record.baseline, internalEnabled: true)
            }
            if scenario == "unresolved" {
                XCTAssertThrowsError(try record.observe(layout(mainExternal: true, internalX: -1900), source: .unknown))
            }
            let actual = scenario == "unknown" ? try layout(mainExternal: true, internalX: -1900)
                : scenario == "pre-disable" ? try XCTUnwrap(record.preDisableLayout) : try externalOnlyLayout()
            var rejected: [InternalRecoveryLayoutContext] = []
            try withStore { store, _ in
                try store.save(record)
                XCTAssertThrowsError(try recoverGuardRecord(
                    store: store, contract: contract(for: record),
                    snapshotReader: { self.snapshot(actual, internalActive: actual.origins[self.internalID] != nil) },
                    internalReader: { _ in
                        if scenario == "wrong-hardware" {
                            return InternalDisplayState(
                                id: 80, identityUUID: self.internalID, isBuiltIn: true, isOnline: true, isActive: false,
                                hardwareIdentity: InternalDisplayHardwareIdentity(bootSession: self.session, registryEntryID: 8),
                                reportedIdentityUUID: self.internalID
                            )
                        }
                        return self.provenInternal(record, active: scenario == "enabled")
                    },
                    enableInternal: { _ in XCTFail("unproven reappearance must not enable: \(scenario)") },
                    originWriter: { _, _ in XCTFail("unproven reappearance must not write layout: \(scenario)") },
                    layoutRejected: { rejected.append($0) }
                ), scenario)
                let retained = try XCTUnwrap(store.load())
                XCTAssertEqual(retained.baseline, record.baseline)
                XCTAssertEqual(retained.generation, record.generation)
                XCTAssertEqual(retained.layoutPending, record.layoutPending)
                XCTAssertEqual(retained.internalDisplay?.pending, record.internalDisplay?.pending)
                XCTAssertEqual(retained.sourceUnresolved, record.sourceUnresolved)
                if scenario == "pre-disable" {
                    XCTAssertEqual(rejected.count, 1)
                    XCTAssertTrue(try XCTUnwrap(rejected.first).matchesPreDisable)
                    XCTAssertFalse(try XCTUnwrap(rejected.first).matchesApplied)
                }
                if scenario == "unknown" {
                    XCTAssertEqual(rejected.count, 1)
                    XCTAssertFalse(try XCTUnwrap(rejected.first).matchesBaseline)
                    XCTAssertFalse(try XCTUnwrap(rejected.first).matchesApplied)
                    XCTAssertFalse(try XCTUnwrap(rejected.first).matchesPreDisable)
                }
            }
        }
    }

    func testKnownBReappearanceCannotSaveResponsibilityAfterSleepOrRecordReplacement() throws {
        for replaced in [false, true] {
            let record = try confirmedCRecord()
            var newer = record
            try newer.prepareReapplication(current: record.baseline, target: layout(mainExternal: true))
            let gate = InternalPowerGate()
            gate.didRegister()
            try withStore { store, _ in
                try store.save(record)
                XCTAssertThrowsError(try recoverGuardRecord(
                    store: store, contract: contract(for: record),
                    snapshotReader: { self.snapshot(try self.externalOnlyLayout(), internalActive: false) },
                    internalReader: { _ in
                        if replaced { try store.save(newer) } else { gate.willSleep() }
                        return self.provenInternal(record, active: false)
                    },
                    enableInternal: { _ in XCTFail("preempted reappearance must not enable") },
                    originWriter: { _, _ in XCTFail("preempted reappearance must not write layout") },
                    checkAccess: { try gate.check() }
                ))
                XCTAssertEqual(try store.load(), replaced ? newer : record)
            }
        }
    }

    func testConfirmedCSnapshotReadCannotOverwriteReplacedResponsibility() throws {
        let record = try confirmedCRecord()
        var newC = record
        try newC.observe(layout(mainExternal: true, internalX: -1900), source: .confirmedUser)
        var unresolved = record
        XCTAssertThrowsError(try unresolved.observe(layout(mainExternal: true, internalX: -1900), source: .unknown))
        for replacement in [newC, unresolved] {
            XCTAssertEqual(replacement.generation, record.generation)
            for actual in [record.baseline, try XCTUnwrap(record.preDisableLayout)] {
                try withStore { store, _ in
                    try store.save(record)
                    var reads = 0
                    XCTAssertThrowsError(try recoverGuardRecord(
                        store: store, contract: contract(for: record),
                        snapshotReader: {
                            reads += 1
                            if reads == 1 { try store.save(replacement) }
                            return self.snapshot(actual)
                        },
                        internalReader: { _ in XCTFail("non-B must not rearm internal responsibility"); throw FixtureError.injected },
                        enableInternal: { _ in XCTFail("replaced record must not enable") },
                        originWriter: { _, _ in XCTFail("replaced record must not write layout") }
                    ))
                    XCTAssertEqual(try store.load(), replacement)
                }
            }
        }
    }

    func testFullLayoutWithoutSuccessfulDisableDoesNotRearmResponsibility() throws {
        let initial = try layout(mainExternal: true)
        let hardware = InternalDisplayHardwareIdentity(bootSession: session, registryEntryID: 7)
        var record = try RecoveryRecord(session: session, baseline: initial, target: initial,
            internalDisplay: InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false, hardwareIdentity: hardware))
        try record.markApplying()
        record.beginRestoration()
        try record.confirmRestored(actual: initial, internalEnabled: true)
        try record.resumeInternalObservation(current: initial, internalEnabled: true)
        try withStore { store, _ in
            try store.save(record)
            let restored = try recoverGuardRecord(
                store: store, contract: contract(for: record), snapshotReader: { self.snapshot(initial) },
                internalReader: { _ in self.provenInternal(record, active: true) },
                enableInternal: { _ in XCTFail("no disable to recover") },
                originWriter: { _, _ in XCTFail("layout already restored") }
            )
            XCTAssertTrue(restored.canClear)
            XCTAssertEqual(restored.baseline, initial)
        }
    }

    func testApplyingRecordEnablesBeforeRestoringOrigins() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)

        try withStore { store, _ in
            try store.save(record)
            var current = self.snapshot(target, internalActive: false)
            var events: [String] = []
            var stages: [InternalLifecycleStage] = []
            let restored = try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: {
                    events.append("snapshot")
                    return current
                },
                internalReader: { identity in
                    events.append("internal")
                    return try current.internalDisplayState(identity: identity)
                },
                enableInternal: { restoring in
                    XCTAssertEqual(restoring.phase, .restoring)
                    XCTAssertEqual(try store.load()?.phase, .restoring)
                    events.append("enable")
                    current = self.snapshot(target, internalActive: true)
                },
                originWriter: { restoring, origins in
                    XCTAssertEqual(try store.load()?.phase, .restoring)
                    events.append("origins")
                    XCTAssertEqual(origins, [
                        80: DisplayOrigin(x: 0, y: 0),
                        40: DisplayOrigin(x: 1728, y: 0)
                    ])
                    current = self.snapshot(baseline)
                },
                trace: { stages.append($0) }
            )

            XCTAssertEqual(events.filter { $0 == "enable" || $0 == "origins" }, ["enable", "origins"])
            XCTAssertEqual(restored.phase, .restored)
            XCTAssertEqual(try store.load(), restored)
            XCTAssertEqual(stages.first, .restorationStarted)
            XCTAssertEqual(stages.last, .restorationVerified)
            XCTAssertLessThan(try XCTUnwrap(stages.firstIndex(of: .enableFinished)),
                              try XCTUnwrap(stages.firstIndex(of: .originsStarted)))
        }
    }

    func testInternalEnableCompletesBeforeFirstFullSnapshotRead() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try ownedRecord(baseline: baseline, target: target)

        try withStore { store, _ in
            try store.save(record)
            var internalEnabled = false
            var currentLayout = target
            var events: [String] = []
            let restored = try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: {
                    events.append("snapshot")
                    guard internalEnabled else { throw FixtureError.injected }
                    return self.snapshot(currentLayout, internalActive: internalEnabled)
                },
                internalReader: { identity in
                    events.append("internal")
                    return InternalDisplayState(
                        id: 80, identityUUID: identity, isBuiltIn: true, isOnline: true, isActive: internalEnabled
                    )
                },
                enableInternal: { restoring in
                    events.append("enable-start")
                    XCTAssertEqual(restoring.phase, .restoring)
                    XCTAssertEqual(try store.load()?.phase, .restoring)
                    internalEnabled = true
                    events.append("enable-complete")
                },
                originWriter: { restoring, origins in
                    events.append("origins")
                    XCTAssertEqual(origins, [
                        80: DisplayOrigin(x: 0, y: 0),
                        40: DisplayOrigin(x: 1728, y: 0)
                    ])
                    currentLayout = baseline
                }
            )

            XCTAssertEqual(events, [
                "internal", "enable-start", "enable-complete", "internal",
                "snapshot", "snapshot", "origins", "snapshot", "internal"
            ])
            XCTAssertEqual(currentLayout, baseline)
            XCTAssertEqual(restored.phase, .restored)
        }
    }

    func testInvalidInternalReadbackRefusesEnableAndOriginsAndKeepsResponsibility() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)
        let invalidStates = [
            InternalDisplayState(id: 80, identityUUID: otherID, isBuiltIn: true, isOnline: true, isActive: false),
            InternalDisplayState(id: 80, identityUUID: internalID, isBuiltIn: false, isOnline: true, isActive: false),
            InternalDisplayState(id: 0, identityUUID: internalID, isBuiltIn: true, isOnline: true, isActive: false)
        ]

        for invalidState in invalidStates {
            try withStore { store, _ in
                try store.save(record)
                var snapshots = 0
                var enables = 0
                var writes = 0

                XCTAssertThrowsError(try recoverGuardRecord(
                    store: store,
                    contract: contract(for: record),
                    snapshotReader: { snapshots += 1; return self.snapshot(target, internalActive: false) },
                    internalReader: { _ in invalidState },
                    enableInternal: { _ in enables += 1 },
                    originWriter: { _, _ in writes += 1 }
                )) { error in
                    guard let recoveryError = error as? RecoveryError,
                          case .identityConflict = recoveryError else {
                        XCTFail("expected identityConflict, got \(error)")
                        return
                    }
                }

                let retained = try XCTUnwrap(store.load())
                XCTAssertEqual(snapshots, 0)
                XCTAssertEqual(enables, 0)
                XCTAssertEqual(writes, 0)
                XCTAssertEqual(retained.phase, .restoring)
                XCTAssertTrue(try XCTUnwrap(retained.internalDisplay).pending)
            }
        }
    }

    func testEnableFailureOrInactiveReadbackLeavesRestorationPending() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)

        for shouldThrow in [true, false] {
            try withStore { store, _ in
                try store.save(record)
                var enableCalls = 0
                var writes = 0
                do {
                    _ = try recoverGuardRecord(
                        store: store,
                        contract: contract(for: record),
                        snapshotReader: { self.snapshot(target, internalActive: false) },
                        internalReader: { identity in
                            try self.snapshot(target, internalActive: false).internalDisplayState(identity: identity)
                        },
                        enableInternal: { restoring in
                            enableCalls += 1
                            XCTAssertEqual(restoring.phase, .restoring)
                            XCTAssertEqual(try store.load()?.phase, .restoring)
                            if shouldThrow { throw FixtureError.injected }
                        },
                        originWriter: { _, _ in writes += 1 }
                    )
                    XCTFail("recovery should remain pending")
                } catch {
                    if shouldThrow {
                        XCTAssertTrue(error is FixtureError)
                    } else if let recoveryError = error as? RecoveryError,
                              case .unfinishedTransaction = recoveryError {
                        // The independent readback still reports the built-in display inactive.
                    } else {
                        XCTFail("unexpected error: \(error)")
                    }
                }

                let retained = try XCTUnwrap(store.load())
                XCTAssertEqual(enableCalls, 1)
                XCTAssertEqual(writes, 0)
                XCTAssertEqual(retained.phase, .restoring)
                XCTAssertTrue(try XCTUnwrap(retained.internalDisplay).pending)
            }
        }
    }

    func testUnresolvedSourceAtSavedBaselineRequiresIndependentFinalConfirmation() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(
            baseline: baseline, target: target,
            unresolvedLayout: try layout(mainExternal: true, internalX: -1900)
        )
        for finalMatches in [true, false] {
            try withStore { store, _ in
                try store.save(record)
                var reads = 0
                let recover = {
                    try recoverGuardRecord(
                        store: store, contract: self.contract(for: record),
                        snapshotReader: {
                            reads += 1
                            return self.snapshot(reads == 1 || finalMatches ? baseline : target)
                        },
                        internalReader: { identity in try self.snapshot(baseline).internalDisplayState(identity: identity) },
                        enableInternal: { _ in XCTFail("already enabled") },
                        originWriter: { _, _ in XCTFail("unresolved source must not write origins") }
                    )
                }
                if finalMatches {
                    XCTAssertTrue(try recover().canClear)
                } else {
                    XCTAssertThrowsError(try recover())
                    XCTAssertTrue(try XCTUnwrap(store.load()).sourceUnresolved)
                    XCTAssertTrue(try XCTUnwrap(store.load()).requiresRecovery)
                }
                XCTAssertEqual(reads, 2)
            }
        }
    }

    func testUnresolvedSourceEnablesInternalButNeverWritesLayout() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(
            baseline: baseline,
            target: target,
            unresolvedLayout: try layout(mainExternal: true, internalX: -1900)
        )

        try withStore { store, _ in
            try store.save(record)
            var current = self.snapshot(target, internalActive: false)
            var enables = 0
            var writes = 0
            XCTAssertThrowsError(try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: { current },
                internalReader: { identity in try current.internalDisplayState(identity: identity) },
                enableInternal: { restoring in
                    enables += 1
                    XCTAssertEqual(restoring.phase, .restoring)
                    XCTAssertTrue(restoring.sourceUnresolved)
                    XCTAssertEqual(try store.load()?.phase, .restoring)
                    current = self.snapshot(target, internalActive: true)
                },
                originWriter: { _, _ in writes += 1 }
            ))

            let retained = try XCTUnwrap(store.load())
            XCTAssertEqual(enables, 1)
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(retained.phase, .restoring)
            XCTAssertTrue(retained.sourceUnresolved)
            XCTAssertTrue(retained.layoutPending)
        }
    }

    func testInvalidHandshakeScopeDoesNotCallBackOrChangeRecordBytes() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)

        try withStore { store, directory in
            try store.save(record)
            let recordURL = directory.appendingPathComponent("recovery-record.json")
            let originalBytes = try Data(contentsOf: recordURL)
            let contracts = [
                try ProtectionHandshake(session: otherSession, generation: record.generation, parentPID: 42, internalDisplayIdentity: internalID),
                try ProtectionHandshake(session: session, generation: record.generation + 1, parentPID: 42, internalDisplayIdentity: internalID),
                try ProtectionHandshake(session: session, generation: record.generation, parentPID: 42, internalDisplayIdentity: otherID),
                try ProtectionHandshake(session: session, generation: record.generation, parentPID: 42)
            ]
            var callbacks = 0

            for contract in contracts {
                XCTAssertThrowsError(try recoverGuardRecord(
                    store: store,
                    contract: contract,
                    snapshotReader: { callbacks += 1; return self.snapshot(baseline) },
                    internalReader: { identity in
                        callbacks += 1
                        return try self.snapshot(baseline).internalDisplayState(identity: identity)
                    },
                    enableInternal: { _ in callbacks += 1 },
                    originWriter: { _, _ in callbacks += 1 }
                ))
                XCTAssertEqual(try Data(contentsOf: recordURL), originalBytes)
            }
            XCTAssertEqual(callbacks, 0)
        }

        let noScopeRecord = try applyingRecord(baseline: baseline, target: target, includesInternal: false)
        try withStore { store, directory in
            try store.save(noScopeRecord)
            let recordURL = directory.appendingPathComponent("recovery-record.json")
            let originalBytes = try Data(contentsOf: recordURL)
            var callbacks = 0
            let scopedContract = try ProtectionHandshake(
                session: noScopeRecord.session,
                generation: noScopeRecord.generation,
                parentPID: 42,
                internalDisplayIdentity: internalID
            )

            XCTAssertThrowsError(try recoverGuardRecord(
                store: store,
                contract: scopedContract,
                snapshotReader: { callbacks += 1; return self.snapshot(baseline) },
                internalReader: { identity in
                    callbacks += 1
                    return try self.snapshot(baseline).internalDisplayState(identity: identity)
                },
                enableInternal: { _ in callbacks += 1 },
                originWriter: { _, _ in callbacks += 1 }
            ))
            XCTAssertEqual(callbacks, 0)
            XCTAssertEqual(try Data(contentsOf: recordURL), originalBytes)
        }
    }

    func testMissingExternalEnablesInternalAndRetainsLayoutResponsibility() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)

        try withStore { store, _ in
            try store.save(record)
            var current = self.snapshot(baseline, internalActive: false, includeExternal: false)
            var events: [String] = []
            XCTAssertThrowsError(try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: { current },
                internalReader: { identity in try current.internalDisplayState(identity: identity) },
                enableInternal: { restoring in
                    events.append("enable")
                    XCTAssertEqual(restoring.phase, .restoring)
                    current = self.snapshot(baseline, includeExternal: false)
                },
                originWriter: { restoring, origins in
                    events.append("origins")
                    XCTAssertEqual(origins, [80: DisplayOrigin(x: 0, y: 0)])
                }
            ))

            let retained = try XCTUnwrap(store.load())
            XCTAssertEqual(events, ["enable", "origins"])
            XCTAssertEqual(current.displays.first(where: { $0.identity == .builtIn })?.isActive, true)
            XCTAssertEqual(retained.phase, .restoring)
            XCTAssertTrue(retained.layoutPending)
            XCTAssertTrue(try XCTUnwrap(retained.internalDisplay).pending)
            XCTAssertFalse(retained.canClear)
        }
    }

    func testHigherGenerationWrittenAfterEnableBlocksOriginsAndKeepsNewRecord() throws {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let record = try applyingRecord(baseline: baseline, target: target)
        var newer = try RecoveryRecord(
            session: record.session,
            baseline: baseline,
            target: target,
            internalDisplay: InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false)
        )
        try newer.markApplying()
        try newer.confirmApplied(try externalOnlyLayout(), internalEnabled: false)
        try newer.prepareReapplication(current: try externalOnlyLayout(), target: try layout(mainExternal: true, internalX: -1900))

        try withStore { store, _ in
            try store.save(record)
            var current = self.snapshot(target, internalActive: false)
            var writes = 0
            XCTAssertThrowsError(try recoverGuardRecord(
                store: store,
                contract: contract(for: record),
                snapshotReader: { current },
                internalReader: { identity in try current.internalDisplayState(identity: identity) },
                enableInternal: { restoring in
                    XCTAssertEqual(restoring.phase, .restoring)
                    XCTAssertEqual(try store.load()?.phase, .restoring)
                    current = self.snapshot(target, internalActive: true)
                    try store.save(newer)
                },
                originWriter: { _, _ in writes += 1 }
            ))

            XCTAssertEqual(writes, 0)
            XCTAssertEqual(try store.load(), newer)
            XCTAssertGreaterThan(try XCTUnwrap(store.load()).generation, record.generation)
        }
    }

    private func applyingRecord(
        baseline: DisplayLayout? = nil,
        target: DisplayLayout? = nil,
        includesInternal: Bool = true,
        unresolvedLayout: DisplayLayout? = nil,
        session: UUID? = nil
    ) throws -> RecoveryRecord {
        let baseline = try baseline ?? layout()
        let target = try target ?? layout(mainExternal: true)
        var record = try RecoveryRecord(
            session: session ?? self.session,
            baseline: baseline,
            target: target,
            internalDisplay: includesInternal
                ? InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false)
                : nil
        )
        try record.markApplying()
        if let unresolvedLayout { try record.observe(unresolvedLayout, source: .unknown) }
        return record
    }

    private func ownedRecord(
        baseline: DisplayLayout,
        target: DisplayLayout,
        includesInternal: Bool = true
    ) throws -> RecoveryRecord {
        var record = try applyingRecord(baseline: baseline, target: target, includesInternal: includesInternal)
        if includesInternal {
            try record.confirmApplied(try externalOnlyLayout(), internalEnabled: false)
        } else {
            try record.confirmApplied(target)
        }
        return record
    }

    private func confirmedCRecord(hardware: Bool = true) throws -> RecoveryRecord {
        let initial = try layout(mainExternal: true)
        var record = try RecoveryRecord(
            session: session, baseline: initial, target: initial,
            internalDisplay: InternalDisplayResponsibility(
                identity: internalID, baseline: true, applied: false,
                hardwareIdentity: hardware ? InternalDisplayHardwareIdentity(bootSession: session, registryEntryID: 7) : nil
            )
        )
        try record.markApplying()
        try record.confirmApplied(externalOnlyLayout(), internalEnabled: false)
        try record.observe(layout(), source: .confirmedUser)
        try record.observeInternalEnabled(true, source: .confirmedUser)
        return record
    }

    private func provenInternal(_ record: RecoveryRecord, active: Bool) -> InternalDisplayState {
        InternalDisplayState(
            id: 80, identityUUID: internalID, isBuiltIn: true, isOnline: true, isActive: active,
            hardwareIdentity: record.internalDisplay?.hardwareIdentity, reportedIdentityUUID: internalID
        )
    }

    private func externalOnlyLayout() throws -> DisplayLayout {
        try DisplayLayout(main: externalID, origins: [externalID: DisplayOrigin(x: 0, y: 0)])
    }

    private func contract(for record: RecoveryRecord) throws -> ProtectionHandshake {
        try ProtectionHandshake(
            session: record.session,
            generation: record.generation,
            parentPID: 42,
            internalDisplayIdentity: record.internalDisplay?.identity,
            internalDisplayHardwareIdentity: record.internalDisplay?.hardwareIdentity
        )
    }

    private func layout(mainExternal: Bool = false, internalX: Int32? = nil) throws -> DisplayLayout {
        try DisplayLayout(main: mainExternal ? externalID : internalID, origins: [
            internalID: DisplayOrigin(x: mainExternal ? (internalX ?? -1728) : 0, y: 0),
            externalID: DisplayOrigin(x: mainExternal ? 0 : 1728, y: 0)
        ])
    }

    private func snapshot(
        _ layout: DisplayLayout,
        internalActive: Bool = true,
        includeExternal: Bool = true
    ) -> Snapshot {
        var displays = [makeDisplay(id: 80, identity: .builtIn, uuid: internalID, layout: layout, isActive: internalActive)]
        if includeExternal {
            displays.append(makeDisplay(id: 40, identity: .physical, uuid: externalID, layout: layout))
        }
        return Snapshot(displays: displays)
    }

    private func makeDisplay(
        id: UInt32,
        identity: DisplayIdentity,
        uuid: UUID,
        layout: DisplayLayout,
        isActive: Bool = true
    ) -> DisplayState {
        let origin = layout.origins[uuid] ?? DisplayOrigin(x: 0, y: 0)
        return DisplayState(
            id: id,
            identity: identity,
            identityUUID: uuid,
            isOnline: true,
            isActive: isActive,
            isMain: layout.main == uuid,
            isMirrored: false,
            originX: CGFloat(origin.x),
            originY: CGFloat(origin.y),
            width: 1920,
            height: 1080,
            rotation: 0,
            mode: DisplayModeState(width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, ioDisplayModeID: 1)
        )
    }

    private func withStore(_ body: (RecoveryStore, URL) throws -> Void) throws {
        let directory = URL(
            fileURLWithPath: "/private/tmp/extilume-guard-recovery-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        guard mkdir(directory.path, mode_t(0o700)) == 0 else { throw RecoveryStoreError.ioFailure }
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            try? FileManager.default.removeItem(at: directory)
            throw RecoveryStoreError.ioFailure
        }
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        try body(store, directory)
    }
}
