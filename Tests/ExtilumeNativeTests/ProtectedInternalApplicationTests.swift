import Foundation
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

final class ProtectedInternalApplicationTests: XCTestCase {
    private let internalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let externalID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let otherID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    private let sessionID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let otherSessionID = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

    private enum FixtureError: Error, Equatable {
        case protectionRevoked
        case snapshotFailure
        case internalReadFailure
        case recoveryGetterFailure
        case recoveryEnableFailure
    }

    private enum RecoveryFailurePoint: Equatable {
        case getter
        case enable
    }

    private final class RecoveryFixture {
        let baseline: DisplayLayout
        var currentLayout: DisplayLayout
        var internalEnabled = true
        var protected = true
        var failurePoint: RecoveryFailurePoint?
        var disableCalls = 0
        var protectionChecks = 0
        var recoveryEnableCalls = 0
        var originWrites = 0

        init(baseline: DisplayLayout, target: DisplayLayout, failurePoint: RecoveryFailurePoint? = nil) {
            self.baseline = baseline
            currentLayout = target
            self.failurePoint = failurePoint
        }
    }

    private enum ExpectedRecoveryError {
        case invalidRecord
        case unfinishedTransaction
    }

    func testStoreApplyPersistsApplyingBeforeProtectedDisableAndConfirmsSingleExternalLayout() throws {
        let baseline = try baselineLayout()
        let target = try targetLayout()
        let prepared = try makePreparedRecord(baseline: baseline, target: target)

        try withStore { store, _ in
            var disableCalls = 0
            let owned = try store.apply(prepared) {
                let durable = try XCTUnwrap(store.load())
                XCTAssertEqual(durable.phase, .applying)
                XCTAssertEqual(durable.internalDisplay, InternalDisplayResponsibility(
                    identity: self.internalID, baseline: true, applied: false
                ))

                let result = try performProtectedInternalDisable(
                    record: durable,
                    loadRecord: { try store.load() },
                    disable: { pending in
                        disableCalls += 1
                        XCTAssertEqual(pending, durable)
                        XCTAssertEqual(try store.load(), pending)
                    },
                    activeSnapshotReader: { self.singleExternalSnapshot(target) },
                    internalReader: { identity in
                        XCTAssertEqual(identity, self.internalID)
                        return self.internalState(isActive: false)
                    },
                    checkProtection: { XCTAssertEqual($0, durable) }
                )
                return result
            }

            XCTAssertEqual(disableCalls, 1)
            XCTAssertEqual(owned.phase, .owned)
            XCTAssertEqual(owned.baseline, baseline)
            XCTAssertEqual(owned.applied, try externalOnlyLayout())
            XCTAssertEqual(owned.preDisableLayout, target)
            XCTAssertEqual(owned.internalDisplay, InternalDisplayResponsibility(
                identity: internalID, baseline: true, applied: false
            ))
            XCTAssertTrue(try XCTUnwrap(owned.internalDisplay).pending)
            XCTAssertEqual(try store.load(), owned)
        }
    }

    func testProtectionMismatchMissingResponsibilityAndWrongPhaseRefuseBeforeDisable() throws {
        let applying = try makeApplyingRecord()

        var disableCalls = 0
        var loadCalls = 0
        XCTAssertThrowsError(try performProtectedInternalDisable(
            record: applying,
            loadRecord: { loadCalls += 1; return applying },
            disable: { _ in disableCalls += 1 },
            activeSnapshotReader: { self.singleExternalSnapshot(try self.targetLayout()) },
            internalReader: { _ in self.internalState(isActive: false) },
            checkProtection: { _ in throw FixtureError.protectionRevoked }
        )) { error in
            XCTAssertEqual(error as? FixtureError, .protectionRevoked)
        }
        XCTAssertEqual(loadCalls, 0)
        XCTAssertEqual(disableCalls, 0)

        let mismatch = try makeApplyingRecord(session: otherSessionID)
        loadCalls = 0
        XCTAssertThrowsError(try performProtectedInternalDisable(
            record: applying,
            loadRecord: { loadCalls += 1; return mismatch },
            disable: { _ in disableCalls += 1 },
            activeSnapshotReader: { self.singleExternalSnapshot(try self.targetLayout()) },
            internalReader: { _ in self.internalState(isActive: false) },
            checkProtection: { _ in }
        )) { error in
            self.assertRecoveryError(error, .unfinishedTransaction)
        }
        XCTAssertEqual(loadCalls, 1)
        XCTAssertEqual(disableCalls, 0)

        let withoutResponsibility = try makeApplyingRecord(includesInternal: false)
        loadCalls = 0
        XCTAssertThrowsError(try performProtectedInternalDisable(
            record: withoutResponsibility,
            loadRecord: { loadCalls += 1; return withoutResponsibility },
            disable: { _ in disableCalls += 1 },
            activeSnapshotReader: { self.singleExternalSnapshot(try self.targetLayout()) },
            internalReader: { _ in self.internalState(isActive: false) },
            checkProtection: { _ in }
        )) { error in
            self.assertRecoveryError(error, .invalidRecord)
        }
        XCTAssertEqual(loadCalls, 0)
        XCTAssertEqual(disableCalls, 0)

        let prepared = try makePreparedRecord()
        loadCalls = 0
        var protectionChecks = 0
        XCTAssertThrowsError(try performProtectedInternalDisable(
            record: prepared,
            loadRecord: { loadCalls += 1; return prepared },
            disable: { _ in disableCalls += 1 },
            activeSnapshotReader: { self.singleExternalSnapshot(try self.targetLayout()) },
            internalReader: { _ in self.internalState(isActive: false) },
            checkProtection: { _ in protectionChecks += 1 }
        )) { error in
            self.assertRecoveryError(error, .invalidRecord)
        }
        XCTAssertEqual(loadCalls, 0)
        XCTAssertEqual(protectionChecks, 0)
        XCTAssertEqual(disableCalls, 0)
    }

    func testUnsafePostDisableReadbacksKeepApplyingResponsibility() throws {
        let target = try targetLayout()
        let invalidReadbacks: [(String, Snapshot, InternalDisplayState)] = [
            ("internal still active", dualSnapshot(target, internalActive: true), internalState(isActive: true)),
            ("active desktop still dual", dualSnapshot(target, internalActive: true), internalState(isActive: false)),
            ("wrong internal UUID", singleExternalSnapshot(target), internalState(identity: otherID, isActive: false)),
            ("wrong internal role", singleExternalSnapshot(target), internalState(isBuiltIn: false, isActive: false)),
            ("zero internal ID", singleExternalSnapshot(target), internalState(id: 0, isActive: false)),
            ("unknown external", singleExternalSnapshot(target, identity: .unknown), internalState(isActive: false)),
            ("inactive external", singleExternalSnapshot(target, externalActive: false), internalState(isActive: false)),
            ("mirrored external", singleExternalSnapshot(target, externalMirrored: true), internalState(isActive: false)),
            ("external UUID changed", singleExternalSnapshot(target, externalUUID: otherID), internalState(isActive: false))
        ]

        for (name, snapshot, readback) in invalidReadbacks {
            try withStore { store, _ in
                let prepared = try makePreparedRecord(target: target)
                var disableCalls = 0
                XCTAssertThrowsError(try store.apply(prepared) {
                    let applying = try XCTUnwrap(store.load())
                    return try performProtectedInternalDisable(
                        record: applying,
                        loadRecord: { try store.load() },
                        disable: { _ in disableCalls += 1 },
                        activeSnapshotReader: { snapshot },
                        internalReader: { _ in readback },
                        checkProtection: { _ in }
                    )
                }, "\(name)") { error in
                    XCTAssertEqual(error as? DisplayEnableTransactionError, .unsafeTopology, name)
                }

                let retained = try XCTUnwrap(store.load())
                XCTAssertEqual(disableCalls, 1, name)
                XCTAssertEqual(retained.phase, .applying, name)
                XCTAssertFalse(retained.sourceUnresolved, name)
                XCTAssertEqual(retained.internalDisplay, InternalDisplayResponsibility(
                    identity: self.internalID, baseline: true, applied: false
                ), name)
                XCTAssertTrue(try XCTUnwrap(retained.internalDisplay).pending, name)
            }
        }
    }

    func testProtectionRevokedDuringSnapshotReadbackRefusesResultAndKeepsApplyingRecord() throws {
        try withStore { store, _ in
            let target = try targetLayout()
            let prepared = try makePreparedRecord(target: target)
            var protected = true
            var disableCalls = 0

            XCTAssertThrowsError(try store.apply(prepared) {
                let applying = try XCTUnwrap(store.load())
                return try performProtectedInternalDisable(
                    record: applying,
                    loadRecord: { try store.load() },
                    disable: { _ in disableCalls += 1 },
                    activeSnapshotReader: {
                        protected = false
                        return self.singleExternalSnapshot(target)
                    },
                    internalReader: { _ in self.internalState(isActive: false) },
                    checkProtection: { _ in
                        guard protected else { throw FixtureError.protectionRevoked }
                    }
                )
            }) { error in
                XCTAssertEqual(error as? FixtureError, .protectionRevoked)
            }

            XCTAssertEqual(disableCalls, 1)
            let retained = try XCTUnwrap(store.load())
            XCTAssertEqual(retained.phase, .applying)
            XCTAssertTrue(try XCTUnwrap(retained.internalDisplay).pending)
        }
    }

    func testNewerGenerationReadDuringInternalReadbackIsNotOverwritten() throws {
        try withStore { store, _ in
            let target = try targetLayout()
            let prepared = try makePreparedRecord(target: target)
            var newer: RecoveryRecord?
            var disableCalls = 0

            XCTAssertThrowsError(try store.apply(prepared) {
                let applying = try XCTUnwrap(store.load())
                return try performProtectedInternalDisable(
                    record: applying,
                    loadRecord: { try store.load() },
                    disable: { _ in disableCalls += 1 },
                    activeSnapshotReader: { self.singleExternalSnapshot(target) },
                    internalReader: { _ in
                        var replacement = applying
                        try replacement.confirmApplied(try self.externalOnlyLayout(), internalEnabled: false)
                        try replacement.prepareReapplication(
                            current: try self.externalOnlyLayout(), target: target
                        )
                        XCTAssertGreaterThan(replacement.generation, applying.generation)
                        try store.save(replacement)
                        newer = replacement
                        return self.internalState(isActive: false)
                    },
                    checkProtection: { _ in }
                )
            }) { error in
                self.assertRecoveryError(error, .unfinishedTransaction)
            }

            XCTAssertEqual(disableCalls, 1)
            let retained = try XCTUnwrap(store.load())
            XCTAssertEqual(retained, try XCTUnwrap(newer))
            XCTAssertGreaterThan(retained.generation, 1)
            XCTAssertEqual(retained.phase, .prepared)
        }
    }

    func testSnapshotAndInternalGetterFailuresRetainApplyingResponsibility() throws {
        let target = try targetLayout()
        for failsAtSnapshot in [true, false] {
            try withStore { store, _ in
                let prepared = try makePreparedRecord(target: target)
                var disableCalls = 0
                XCTAssertThrowsError(try store.apply(prepared) {
                    let applying = try XCTUnwrap(store.load())
                    return try performProtectedInternalDisable(
                        record: applying,
                        loadRecord: { try store.load() },
                        disable: { _ in disableCalls += 1 },
                        activeSnapshotReader: {
                            if failsAtSnapshot { throw FixtureError.snapshotFailure }
                            return self.singleExternalSnapshot(target)
                        },
                        internalReader: { _ in
                            if !failsAtSnapshot { throw FixtureError.internalReadFailure }
                            return self.internalState(isActive: false)
                        },
                        checkProtection: { _ in }
                    )
                }) { error in
                    XCTAssertEqual(error as? FixtureError,
                                   failsAtSnapshot ? .snapshotFailure : .internalReadFailure)
                }

                XCTAssertEqual(disableCalls, 1)
                let retained = try XCTUnwrap(store.load())
                XCTAssertEqual(retained.phase, .applying)
                XCTAssertTrue(try XCTUnwrap(retained.internalDisplay).pending)
            }
        }
    }

    func testProtectionLossRecoveryRestoresBaselineAndWrapperReturnsNil() throws {
        let baseline = try baselineLayout()
        let target = try targetLayout()
        let prepared = try makePreparedRecord(baseline: baseline, target: target)

        try withStore { store, _ in
            let fixture = RecoveryFixture(baseline: baseline, target: target)
            var callbackCalls = 0
            var operationRecord: RecoveryRecord?
            var callbackRecord: RecoveryRecord?
            var restored: RecoveryRecord?
            var recoveryError: Error?
            var contract: ProtectionHandshake?

            let result = try applyProtectedInternalRecord(
                store: store,
                prepared: prepared,
                operation: { applying in
                    operationRecord = applying
                    return try self.performDisable(record: applying, store: store, fixture: fixture)
                },
                recoverOnFailure: { applying in
                    callbackCalls += 1
                    callbackRecord = applying
                    XCTAssertEqual(try? store.load(), applying)
                    do {
                        let recoveryContract = try self.protectionContract(for: applying)
                        contract = recoveryContract
                        restored = try self.recover(fixture, store: store, contract: recoveryContract)
                    } catch {
                        recoveryError = error
                    }
                }
            )

            XCTAssertNil(result)
            XCTAssertNil(recoveryError)
            XCTAssertEqual(callbackCalls, 1)
            XCTAssertEqual(fixture.disableCalls, 1)
            XCTAssertEqual(fixture.protectionChecks, 2)
            XCTAssertEqual(callbackRecord, operationRecord)
            XCTAssertEqual(callbackRecord?.phase, .applying)
            XCTAssertEqual(callbackRecord?.session, prepared.session)
            XCTAssertEqual(callbackRecord?.baseline, baseline)
            XCTAssertEqual(fixture.recoveryEnableCalls, 1)
            XCTAssertEqual(fixture.originWrites, 1)
            XCTAssertTrue(fixture.internalEnabled)
            XCTAssertEqual(fixture.currentLayout, baseline)

            let recovered = try XCTUnwrap(restored)
            XCTAssertEqual(recovered.phase, .restored)
            XCTAssertTrue(recovered.canClear)
            XCTAssertEqual(recovered.session, prepared.session)
            XCTAssertEqual(recovered.generation, prepared.generation)
            XCTAssertEqual(recovered.baseline, baseline)
            XCTAssertEqual(try store.load(), recovered)
            XCTAssertNotNil(try store.load(), "recovery responsibility remains until explicit clear")
            XCTAssertEqual(try XCTUnwrap(contract), try protectionContract(for: prepared))
        }
    }

    func testFailedRecoveryKeepsRetryResponsibilityAndCanRetryWithoutChangingScope() throws {
        let baseline = try baselineLayout()
        let target = try targetLayout()

        for failurePoint in [RecoveryFailurePoint.getter, .enable] {
            try withStore { store, _ in
                let prepared = try makePreparedRecord(baseline: baseline, target: target)
                let fixture = RecoveryFixture(
                    baseline: baseline, target: target, failurePoint: failurePoint
                )
                var callbackCalls = 0
                var operationRecord: RecoveryRecord?
                var callbackRecord: RecoveryRecord?
                var localRetryRecord: RecoveryRecord?
                var retainedAfterFailure: RecoveryRecord?
                var recoveryError: FixtureError?
                var contract: ProtectionHandshake?

                let result = try applyProtectedInternalRecord(
                    store: store,
                    prepared: prepared,
                    operation: { applying in
                        operationRecord = applying
                        return try self.performDisable(record: applying, store: store, fixture: fixture)
                    },
                    recoverOnFailure: { applying in
                        callbackCalls += 1
                        callbackRecord = applying
                        localRetryRecord = applying
                        XCTAssertEqual(try? store.load(), applying)
                        do {
                            let recoveryContract = try self.protectionContract(for: applying)
                            contract = recoveryContract
                            _ = try self.recover(fixture, store: store, contract: recoveryContract)
                        } catch {
                            recoveryError = error as? FixtureError
                            retainedAfterFailure = try? store.load()
                            localRetryRecord = retainedAfterFailure ?? applying
                        }
                    }
                )

                XCTAssertNil(result)
                XCTAssertEqual(callbackCalls, 1)
                XCTAssertEqual(fixture.disableCalls, 1)
                XCTAssertEqual(operationRecord, callbackRecord)
                XCTAssertEqual(callbackRecord?.phase, .applying)
                XCTAssertEqual(recoveryError, failurePoint == .getter
                    ? .recoveryGetterFailure : .recoveryEnableFailure)
                XCTAssertEqual(fixture.originWrites, 0)

                let pending = try XCTUnwrap(retainedAfterFailure)
                XCTAssertEqual(pending, try XCTUnwrap(store.load()))
                XCTAssertEqual(try XCTUnwrap(localRetryRecord), pending)
                XCTAssertEqual(pending.phase, .restoring)
                XCTAssertTrue(pending.requiresRecovery)
                XCTAssertTrue(try XCTUnwrap(pending.internalDisplay).pending)
                XCTAssertEqual(pending.internalDisplay?.identity, internalID)
                XCTAssertEqual(pending.session, prepared.session)
                XCTAssertEqual(pending.generation, prepared.generation)
                XCTAssertEqual(pending.baseline, baseline)
                XCTAssertEqual(pending.applied, target)

                let recoveryContract = try XCTUnwrap(contract)
                let retried = try recover(fixture, store: store, contract: recoveryContract)
                XCTAssertEqual(fixture.originWrites, 1)
                XCTAssertTrue(fixture.internalEnabled)
                XCTAssertEqual(fixture.currentLayout, baseline)
                XCTAssertEqual(retried.phase, .restored)
                XCTAssertTrue(retried.canClear)
                XCTAssertEqual(retried.internalDisplay?.identity, pending.internalDisplay?.identity)
                XCTAssertEqual(retried.session, pending.session)
                XCTAssertEqual(retried.generation, pending.generation)
                XCTAssertEqual(retried.baseline, pending.baseline)
                XCTAssertEqual(retried.applied, pending.applied)
                XCTAssertEqual(try store.load(), retried)
            }
        }
    }

    private func makePreparedRecord(
        baseline: DisplayLayout? = nil,
        target: DisplayLayout? = nil,
        includesInternal: Bool = true,
        session: UUID? = nil
    ) throws -> RecoveryRecord {
        try RecoveryRecord(
            session: session ?? sessionID,
            baseline: try baseline ?? baselineLayout(),
            target: try target ?? targetLayout(),
            internalDisplay: includesInternal
                ? InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false)
                : nil
        )
    }

    private func makeApplyingRecord(
        includesInternal: Bool = true,
        session: UUID? = nil
    ) throws -> RecoveryRecord {
        var record = try makePreparedRecord(includesInternal: includesInternal, session: session)
        try record.markApplying()
        return record
    }

    private func baselineLayout() throws -> DisplayLayout {
        try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 1728, y: 0)
        ])
    }

    private func targetLayout() throws -> DisplayLayout {
        try DisplayLayout(main: externalID, origins: [
            internalID: DisplayOrigin(x: -1728, y: 0),
            externalID: DisplayOrigin(x: 0, y: 0)
        ])
    }

    private func externalOnlyLayout() throws -> DisplayLayout {
        try DisplayLayout(main: externalID, origins: [externalID: DisplayOrigin(x: 0, y: 0)])
    }

    private func performDisable(
        record: RecoveryRecord,
        store: RecoveryStore,
        fixture: RecoveryFixture
    ) throws -> (layout: DisplayLayout, internalEnabled: Bool?) {
        try performProtectedInternalDisable(
            record: record,
            loadRecord: { try store.load() },
            disable: { pending in
                XCTAssertEqual(pending, record)
                fixture.disableCalls += 1
                fixture.internalEnabled = false
            },
            activeSnapshotReader: {
                fixture.protected = false
                return self.singleExternalSnapshot(fixture.currentLayout)
            },
            internalReader: { identity in
                self.internalState(identity: identity, isActive: fixture.internalEnabled)
            },
            checkProtection: { _ in
                fixture.protectionChecks += 1
                guard fixture.protected else { throw FixtureError.protectionRevoked }
            }
        )
    }

    private func recover(
        _ fixture: RecoveryFixture,
        store: RecoveryStore,
        contract: ProtectionHandshake
    ) throws -> RecoveryRecord {
        try recoverGuardRecord(
            store: store,
            contract: contract,
            snapshotReader: {
                fixture.internalEnabled
                    ? self.dualSnapshot(fixture.currentLayout, internalActive: true)
                    : self.singleExternalSnapshot(fixture.currentLayout)
            },
            internalReader: { identity in
                if fixture.failurePoint == .getter {
                    fixture.failurePoint = nil
                    throw FixtureError.recoveryGetterFailure
                }
                return self.internalState(identity: identity, isActive: fixture.internalEnabled)
            },
            enableInternal: { record in
                fixture.recoveryEnableCalls += 1
                XCTAssertEqual(record.phase, .restoring)
                XCTAssertEqual(try store.load(), record)
                if fixture.failurePoint == .enable {
                    fixture.failurePoint = nil
                    throw FixtureError.recoveryEnableFailure
                }
                fixture.internalEnabled = true
            },
            originWriter: { origins in
                fixture.originWrites += 1
                XCTAssertEqual(origins, [
                    80: DisplayOrigin(x: 0, y: 0),
                    40: DisplayOrigin(x: 1728, y: 0)
                ])
                XCTAssertEqual(try store.load()?.phase, .restoring)
                fixture.currentLayout = fixture.baseline
            }
        )
    }

    private func protectionContract(for record: RecoveryRecord) throws -> ProtectionHandshake {
        try ProtectionHandshake(
            session: record.session,
            generation: record.generation,
            parentPID: 42,
            internalDisplayIdentity: record.internalDisplay?.identity
        )
    }

    private func singleExternalSnapshot(
        _ layout: DisplayLayout,
        identity: DisplayIdentity = .physical,
        externalUUID: UUID? = nil,
        externalActive: Bool = true,
        externalMirrored: Bool = false
    ) -> Snapshot {
        let uuid = externalUUID ?? externalID
        return Snapshot(displays: [display(
            id: 40,
            identity: identity,
            uuid: uuid,
            layout: layout,
            isActive: externalActive,
            isMain: true,
            isMirrored: externalMirrored,
            origin: layout.origins[externalID] ?? DisplayOrigin(x: 0, y: 0)
        )])
    }

    private func dualSnapshot(_ layout: DisplayLayout, internalActive: Bool) -> Snapshot {
        Snapshot(displays: [
            display(id: 80, identity: .builtIn, uuid: internalID, layout: layout, isActive: internalActive),
            display(id: 40, identity: .physical, uuid: externalID, layout: layout)
        ])
    }

    private func internalState(
        id: UInt32 = 80,
        identity: UUID? = nil,
        isBuiltIn: Bool = true,
        isActive: Bool
    ) -> InternalDisplayState {
        InternalDisplayState(
            id: id,
            identityUUID: identity ?? internalID,
            isBuiltIn: isBuiltIn,
            isOnline: true,
            isActive: isActive
        )
    }

    private func display(
        id: UInt32,
        identity: DisplayIdentity,
        uuid: UUID,
        layout: DisplayLayout,
        isOnline: Bool = true,
        isActive: Bool = true,
        isMain: Bool? = nil,
        isMirrored: Bool = false,
        origin: DisplayOrigin? = nil
    ) -> DisplayState {
        let position = origin ?? layout.origins[uuid] ?? DisplayOrigin(x: 0, y: 0)
        return DisplayState(
            id: id,
            identity: identity,
            identityUUID: uuid,
            isOnline: isOnline,
            isActive: isActive,
            isMain: isMain ?? (layout.main == uuid),
            isMirrored: isMirrored,
            originX: CGFloat(position.x),
            originY: CGFloat(position.y),
            width: 1920,
            height: 1080,
            rotation: 0,
            mode: DisplayModeState(
                width: 1920, height: 1080, pixelWidth: 1920, pixelHeight: 1080,
                refreshRate: 60, ioDisplayModeID: 1
            )
        )
    }

    private func withStore(_ body: (RecoveryStore, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtilumeProtectedInternalApplication-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let permissions = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions.map { $0.intValue & 0o7777 }, 0o700)
        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        try body(store, directory)
    }

    private func assertRecoveryError(
        _ error: Error,
        _ expected: ExpectedRecoveryError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual = error as? RecoveryError else {
            XCTFail("expected RecoveryError, got \(error)", file: file, line: line)
            return
        }
        switch expected {
        case .invalidRecord:
            if case .invalidRecord = actual { return }
        case .unfinishedTransaction:
            if case .unfinishedTransaction = actual { return }
        }
        XCTFail("unexpected RecoveryError: \(actual)", file: file, line: line)
    }
}
