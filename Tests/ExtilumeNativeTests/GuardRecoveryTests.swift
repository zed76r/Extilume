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
                originWriter: { _ in writes += 1 }
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
                originWriter: { _ in writes += 1 }
            )

            XCTAssertEqual(enables, 0)
            XCTAssertEqual(writes, 0)
            XCTAssertEqual(restored.phase, .restored)
            XCTAssertFalse(try XCTUnwrap(restored.internalDisplay).pending)
            XCTAssertEqual(try store.load(), restored)
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
                originWriter: { origins in
                    XCTAssertEqual(try store.load()?.phase, .restoring)
                    events.append("origins")
                    XCTAssertEqual(origins, [
                        80: DisplayOrigin(x: 0, y: 0),
                        40: DisplayOrigin(x: 1728, y: 0)
                    ])
                    current = self.snapshot(baseline)
                }
            )

            XCTAssertEqual(events.filter { $0 == "enable" || $0 == "origins" }, ["enable", "origins"])
            XCTAssertEqual(restored.phase, .restored)
            XCTAssertEqual(try store.load(), restored)
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
                originWriter: { origins in
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
                    originWriter: { _ in writes += 1 }
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
                        originWriter: { _ in writes += 1 }
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
                        originWriter: { _ in XCTFail("unresolved source must not write origins") }
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
                originWriter: { _ in writes += 1 }
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
                    originWriter: { _ in callbacks += 1 }
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
                originWriter: { _ in callbacks += 1 }
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
                originWriter: { origins in
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
                originWriter: { _ in writes += 1 }
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

    private func externalOnlyLayout() throws -> DisplayLayout {
        try DisplayLayout(main: externalID, origins: [externalID: DisplayOrigin(x: 0, y: 0)])
    }

    private func contract(for record: RecoveryRecord) throws -> ProtectionHandshake {
        try ProtectionHandshake(
            session: record.session,
            generation: record.generation,
            parentPID: 42,
            internalDisplayIdentity: record.internalDisplay?.identity
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
