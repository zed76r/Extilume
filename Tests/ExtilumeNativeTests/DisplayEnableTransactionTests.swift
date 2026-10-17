import CoreGraphics
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class DisplayEnableTransactionTests: XCTestCase {
    private let internalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let externalID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let session = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let otherSession = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!
    private var internalHardwareIdentity: InternalDisplayHardwareIdentity {
        InternalDisplayHardwareIdentity(bootSession: session, registryEntryID: 123)
    }

    private enum ValidationError: Error, Equatable {
        case revoked
    }

    private enum StagedChange: Hashable {
        case protection
        case record
        case builtInID
        case externalID
    }

    private final class FakeCalls {
        private let token = NSObject()
        let handle: CGDisplayConfigRef
        var events: [String] = []

        init() {
            // This fake handle is only observed by injected closures and never passed to CoreGraphics.
            handle = unsafeBitCast(Unmanaged.passUnretained(token).toOpaque(), to: CGDisplayConfigRef.self)
        }

        func transaction(
            configureAvailable: Bool = true,
            beginResult: CGError = .success,
            providesHandle: Bool = true,
            configureResult: CGError = .success,
            completeResult: CGError = .success,
            cancelResult: CGError = .success,
            configureHook: (() -> Void)? = nil
        ) -> DisplayEnableTransaction {
            let configure: DisplayEnableTransaction.Configure?
            if configureAvailable {
                configure = { [self] _, display, enabled in
                    events.append("configure:\(display):\(enabled)")
                    configureHook?()
                    return configureResult
                }
            } else {
                configure = nil
            }
            return DisplayEnableTransaction(
                configure: configure,
                begin: { [self] output in
                    events.append("begin")
                    output.pointee = beginResult == .success && providesHandle ? handle : nil
                    return beginResult
                },
                complete: { [self] _, option in
                    events.append("complete:\(option.rawValue)")
                    return completeResult
                },
                cancel: { [self] _ in
                    events.append("cancel")
                    return cancelResult
                }
            )
        }
    }

    func testMissingSymbolAndNullDisplayRefuseBeforeNativeCalls() {
        let missingSymbol = FakeCalls()
        let missingSymbolTransaction = missingSymbol.transaction(configureAvailable: false)
        XCTAssertThrowsError(try missingSymbolTransaction.setEnabled(display: 42, enabled: true, validate: {})) {
            XCTAssertEqual($0 as? DisplayEnableTransactionError, .symbolUnavailable)
        }
        XCTAssertTrue(missingSymbol.events.isEmpty)

        let nullDisplay = FakeCalls()
        let nullDisplayTransaction = nullDisplay.transaction()
        XCTAssertThrowsError(try nullDisplayTransaction.setEnabled(display: kCGNullDirectDisplay, enabled: true, validate: {})) {
            XCTAssertEqual($0 as? DisplayEnableTransactionError, .invalidDisplay)
        }
        XCTAssertTrue(nullDisplay.events.isEmpty)
    }

    func testValidationRejectionBeforeBeginMakesNoNativeCalls() {
        let fake = FakeCalls()
        let transaction = fake.transaction()
        var validations = 0

        XCTAssertThrowsError(try transaction.setEnabled(display: 42, enabled: true) {
            validations += 1
            throw ValidationError.revoked
        }) {
            XCTAssertEqual($0 as? ValidationError, .revoked)
        }
        XCTAssertEqual(validations, 1)
        XCTAssertTrue(fake.events.isEmpty)
    }

    func testBeginFailureAndMissingHandleRefuseWithoutStaging() {
        for (beginResult, providesHandle) in [(CGError.failure, true), (.success, false)] {
            let fake = FakeCalls()
            let transaction = fake.transaction(beginResult: beginResult, providesHandle: providesHandle)

            XCTAssertThrowsError(try transaction.setEnabled(display: 42, enabled: true, validate: {})) {
                XCTAssertEqual($0 as? DisplayEnableTransactionError, .beginFailed)
            }
            XCTAssertEqual(fake.events, ["begin"])
        }
    }

    func testConfigureFailureCancelsStagedConfiguration() {
        let fake = FakeCalls()
        let transaction = fake.transaction(configureResult: .failure)

        XCTAssertThrowsError(try transaction.setEnabled(display: 42, enabled: false, validate: {})) {
            XCTAssertEqual($0 as? DisplayEnableTransactionError, .configurationFailed)
        }
        XCTAssertEqual(fake.events, ["begin", "configure:42:false", "cancel"])
    }

    func testRevocationAfterStagingCancelsWithoutCompleting() {
        let fake = FakeCalls()
        let transaction = fake.transaction()
        var validations = 0

        XCTAssertThrowsError(try transaction.setEnabled(display: 42, enabled: false) {
            validations += 1
            if validations == 2 { throw ValidationError.revoked }
        }) {
            XCTAssertEqual($0 as? ValidationError, .revoked)
        }
        XCTAssertEqual(validations, 2)
        XCTAssertEqual(fake.events, ["begin", "configure:42:false", "cancel"])
    }

    func testSuccessfulDisableAndEnableUseExpectedCommitOptions() {
        for (enabled, expectedOption) in [(false, CGConfigureOption.forAppOnly), (true, .forSession)] {
            let fake = FakeCalls()
            let transaction = fake.transaction()

            XCTAssertNoThrow(try transaction.setEnabled(display: 42, enabled: enabled, validate: {}))
            XCTAssertEqual(fake.events, ["begin", "configure:42:\(enabled)", "complete:\(expectedOption.rawValue)"])
        }
    }

    func testCompleteFailureDoesNotCancelConsumedHandle() {
        let fake = FakeCalls()
        let transaction = fake.transaction(completeResult: .failure)

        XCTAssertThrowsError(try transaction.setEnabled(display: 42, enabled: true, validate: {})) {
            XCTAssertEqual($0 as? DisplayEnableTransactionError, .commitFailed)
        }
        XCTAssertEqual(fake.events, ["begin", "configure:42:true", "complete:\(CGConfigureOption.forSession.rawValue)"])
    }

    func testDisableInternalUsesReadyProtectionAndAppOnlyOption() throws {
        let record = try makeRecord()
        XCTAssertEqual(record.phase, .applying)
        XCTAssertEqual(record.internalDisplay?.baseline, true)
        XCTAssertEqual(record.internalDisplay?.applied, false)
        let protection = try readyProtection(for: record)
        let snapshot = makeSnapshot(try layout(mainExternal: true))
        let fake = FakeCalls()

        try runDisable(
            fake.transaction(), record: record, storedRecord: { record }, snapshotReader: { snapshot },
            checkProtection: { try protection.authorize(record: $0) }
        )

        XCTAssertEqual(fake.events, [
            "begin", "configure:80:false", "complete:\(CGConfigureOption.forAppOnly.rawValue)"
        ])
    }

    func testDisableInternalRejectsMissingHardwareIdentityBeforeNativeCalls() throws {
        let record = try makeRecord(includeHardwareIdentity: false)
        let fake = FakeCalls()
        var snapshotReads = 0
        var internalReads = 0

        XCTAssertThrowsError(try runDisable(
            fake.transaction(), record: record, storedRecord: { record },
            snapshotReader: {
                snapshotReads += 1
                return makeSnapshot(try layout(mainExternal: true))
            },
            internalReader: { _ in
                internalReads += 1
                throw RecoveryError.identityConflict
            },
            checkProtection: { _ in }
        ))

        XCTAssertEqual(snapshotReads, 0)
        XCTAssertEqual(internalReads, 0)
        XCTAssertTrue(fake.events.isEmpty)
    }

    func testDisableInternalRejectsUnsupportedTopologyOrClosedLidBeforeNativeCalls() throws {
        let record = try makeRecord()
        let protection = try readyProtection(for: record)
        let applied = try layout(mainExternal: true)
        let cases: [(String, Snapshot, Bool, Bool)] = [
            ("unknown external", makeSnapshot(applied, externalIdentity: .unknown), true, true),
            ("missing external", makeSnapshot(applied, includeExternal: false), true, true),
            ("external is not main", makeSnapshot(try layout()), true, true),
            ("lid closed or unknown", makeSnapshot(applied), false, true),
            ("missing symbol", makeSnapshot(applied), true, false)
        ]

        for (name, snapshot, lidIsOpen, configureAvailable) in cases {
            let fake = FakeCalls()
            XCTAssertThrowsError(try runDisable(
                fake.transaction(configureAvailable: configureAvailable),
                record: record,
                storedRecord: { record },
                snapshotReader: { snapshot },
                lidIsOpen: { lidIsOpen },
                checkProtection: { try protection.authorize(record: $0) }
            ), name)
            XCTAssertTrue(fake.events.isEmpty, name)
        }
    }

    func testDisableInternalRejectsMissingChangedOrInvalidRecordAndProtectionBeforeNativeCalls() throws {
        let record = try makeRecord()
        let applied = try layout(mainExternal: true)
        let snapshot = makeSnapshot(applied)

        func assertRejected(
            record: RecoveryRecord,
            storedRecord: RecoveryRecord?,
            protection: ProtectionAuthorization
        ) {
            let fake = FakeCalls()
            XCTAssertThrowsError(try runDisable(
                fake.transaction(), record: record, storedRecord: { storedRecord },
                snapshotReader: { snapshot },
                checkProtection: { try protection.authorize(record: $0) }
            ))
            XCTAssertTrue(fake.events.isEmpty)
        }

        let ready = try readyProtection(for: record)
        assertRejected(record: record, storedRecord: nil, protection: ready)
        assertRejected(
            record: record,
            storedRecord: try makeRecord(session: otherSession),
            protection: ready
        )
        assertRejected(
            record: record,
            storedRecord: try makeNewerApplyingRecord(),
            protection: ready
        )
        assertRejected(
            record: try makeRecord(applying: false),
            storedRecord: try makeRecord(applying: false),
            protection: ready
        )
        assertRejected(
            record: try makeRecord(internalBaseline: false, internalApplied: true),
            storedRecord: try makeRecord(internalBaseline: false, internalApplied: true),
            protection: ready
        )
        assertRejected(
            record: try makeRecord(includeResponsibility: false),
            storedRecord: try makeRecord(includeResponsibility: false),
            protection: ready
        )
        assertRejected(
            record: try makeRecord(internalIdentity: externalID),
            storedRecord: try makeRecord(internalIdentity: externalID),
            protection: ready
        )
        let unresolved = try makeUnresolvedApplyingRecord()
        assertRejected(record: unresolved, storedRecord: unresolved, protection: try readyProtection(for: unresolved))
        assertRejected(record: record, storedRecord: record, protection: ProtectionAuthorization())

        var lost = try readyProtection(for: record)
        lost.markLost()
        assertRejected(record: record, storedRecord: record, protection: lost)
    }

    func testDisableInternalCancelsAfterStagingWhenProtectionRecordOrDisplayChanges() throws {
        let record = try makeRecord()
        let otherRecord = try makeRecord(session: otherSession)
        let applied = try layout(mainExternal: true)
        let replacementSnapshots: [StagedChange: Snapshot] = [
            .builtInID: makeSnapshot(applied, internalDisplayID: 81),
            .externalID: makeSnapshot(applied, externalDisplayID: 41)
        ]

        for change in [StagedChange.protection, .record, .builtInID, .externalID] {
            var protection = try readyProtection(for: record)
            var storedRecord: RecoveryRecord? = record
            var snapshot = makeSnapshot(applied)
            let fake = FakeCalls()
            let transaction = fake.transaction(configureHook: {
                switch change {
                case .protection:
                    protection.markLost()
                case .record:
                    storedRecord = otherRecord
                case .builtInID, .externalID:
                    snapshot = replacementSnapshots[change]!
                }
            })

            XCTAssertThrowsError(try runDisable(
                transaction, record: record, storedRecord: { storedRecord }, snapshotReader: { snapshot },
                checkProtection: { try protection.authorize(record: $0) }
            ))
            XCTAssertEqual(fake.events, ["begin", "configure:80:false", "cancel"])
        }
    }

    func testDisableInternalCancelsBeforeCommitWhenHardwareIdentityChanges() throws {
        let record = try makeRecord()
        let snapshot = makeSnapshot(try layout(mainExternal: true))
        let protection = try readyProtection(for: record)
        var currentHardwareIdentity = internalHardwareIdentity
        var internalReads = 0
        let fake = FakeCalls()

        XCTAssertThrowsError(try runDisable(
            fake.transaction(configureHook: {
                currentHardwareIdentity = InternalDisplayHardwareIdentity(bootSession: self.session, registryEntryID: 124)
            }), record: record, storedRecord: { record }, snapshotReader: { snapshot },
            internalReader: { identity in
                internalReads += 1
                return self.internalState(identity: identity, hardwareIdentity: currentHardwareIdentity)
            },
            checkProtection: { try protection.authorize(record: $0) }
        ))

        XCTAssertEqual(internalReads, 3)
        XCTAssertEqual(fake.events, ["begin", "configure:80:false", "cancel"])
    }

    func testDisableInternalRejectsProtectionLostDuringSnapshotReadAndCancels() throws {
        let record = try makeRecord()
        let snapshot = makeSnapshot(try layout(mainExternal: true))

        for revokeOnRead in [2, 3] {
            var protection = try readyProtection(for: record)
            var snapshotReads = 0
            let fake = FakeCalls()

            XCTAssertThrowsError(try runDisable(
                fake.transaction(), record: record, storedRecord: { record },
                snapshotReader: {
                    snapshotReads += 1
                    if snapshotReads == revokeOnRead { protection.markLost() }
                    return snapshot
                },
                checkProtection: { try protection.authorize(record: $0) }
            ))

            XCTAssertEqual(snapshotReads, revokeOnRead)
            let expectedEvents = revokeOnRead == 2
                ? []
                : ["begin", "configure:80:false", "cancel"]
            XCTAssertEqual(fake.events, expectedEvents)
        }
    }

    func testDisableAfterRestorationAcceptsChangedRuntimeUUIDOnlyWithSameHardwareProof() throws {
        let record = try makeRecord()
        let protection = try readyProtection(for: record)
        let runtimeID = UUID(uuidString: "00000000-0000-4000-8000-000000000099")!
        var displays = makeSnapshot(try layout(mainExternal: true)).displays
        displays[0].identityUUID = runtimeID
        let snapshot = Snapshot(displays: displays)

        for reportedID in [runtimeID, internalID] {
            let fake = FakeCalls()
            let apply = {
                try self.runDisable(
                    fake.transaction(), record: record, storedRecord: { record }, snapshotReader: { snapshot },
                    internalReader: { _ in
                        InternalDisplayState(
                            id: 80, identityUUID: self.internalID, isBuiltIn: true, isOnline: true, isActive: true,
                            hardwareIdentity: self.internalHardwareIdentity, reportedIdentityUUID: reportedID
                        )
                    },
                    checkProtection: { try protection.authorize(record: $0) }
                )
            }
            if reportedID == runtimeID {
                XCTAssertNoThrow(try apply())
                XCTAssertEqual(fake.events, ["begin", "configure:80:false", "complete:\(CGConfigureOption.forAppOnly.rawValue)"])
            } else {
                XCTAssertThrowsError(try apply())
                XCTAssertTrue(fake.events.isEmpty)
            }
        }
    }

    func testRecoveryEnablesBuiltInWithoutExternalOrReadyProtectionAndLeavesRecordAlone() throws {
        let record = try makeRestoringRecord(sourceUnresolved: true)
        let snapshot = makeSnapshot(try layout(mainExternal: true), internalActive: false, includeExternal: false)
        let fake = FakeCalls()

        try fake.transaction().enableInternalForRecovery(
            record: record, loadRecord: { record },
            internalReader: { identity in
                let state = try snapshot.internalDisplayState(identity: identity)
                return InternalDisplayState(id: state.id, identityUUID: state.identityUUID, isBuiltIn: state.isBuiltIn,
                                            isOnline: state.isOnline, isActive: state.isActive,
                                            hardwareIdentity: record.internalDisplay?.hardwareIdentity,
                                            reportedIdentityUUID: state.identityUUID)
            }
        )

        XCTAssertEqual(fake.events, [
            "begin", "configure:80:true", "complete:\(CGConfigureOption.forSession.rawValue)"
        ])
        XCTAssertEqual(record.phase, .restoring)
        XCTAssertTrue(record.sourceUnresolved)
        XCTAssertTrue(record.internalDisplay?.pending == true)
    }

    func testRecoveryTraceReportsExactSuccessfulEnableStagesIncludingIdentityReads() throws {
        let record = try makeRestoringRecord(sourceUnresolved: true)
        let fake = FakeCalls()
        var traceEntries: [String] = []
        let trace: DisplayEnableTransaction.Trace = { stage, status in
            traceEntries.append(self.lifecycleEvent(stage, status))
        }

        try fake.transaction().enableInternalForRecovery(
            record: record, loadRecord: { record }, trace: trace,
            internalReader: { identity in self.internalState(identity: identity, hardwareIdentity: self.internalHardwareIdentity) }
        )

        XCTAssertEqual(traceEntries, [
            lifecycleEvent(.enableIdentityReadStarted), lifecycleEvent(.enableIdentityReadFinished),
            lifecycleEvent(.enablePreValidationStarted),
            lifecycleEvent(.enableIdentityReadStarted), lifecycleEvent(.enableIdentityReadFinished),
            lifecycleEvent(.enablePreValidationFinished),
            lifecycleEvent(.enableBeginStarted), lifecycleEvent(.enableBeginFinished, .success),
            lifecycleEvent(.enableConfigureStarted), lifecycleEvent(.enableConfigureFinished, .success),
            lifecycleEvent(.enablePostValidationStarted),
            lifecycleEvent(.enableIdentityReadStarted), lifecycleEvent(.enableIdentityReadFinished),
            lifecycleEvent(.enablePostValidationFinished), lifecycleEvent(.enableCompleteStarted),
            lifecycleEvent(.enableCompleteFinished, .success)
        ])
        XCTAssertEqual(fake.events, ["begin", "configure:80:true", "complete:\(CGConfigureOption.forSession.rawValue)"])
    }

    func testEnableTraceCancelsAfterConfigurationOrReadFailureWithoutCompletion() throws {
        let configureFake = FakeCalls()
        var configureTrace: [String] = []
        let configureRecorder: DisplayEnableTransaction.Trace = { stage, status in
            configureTrace.append(self.lifecycleEvent(stage, status))
        }
        XCTAssertThrowsError(try configureFake.transaction(configureResult: .failure).setEnabled(
            display: 42, enabled: true, trace: configureRecorder, validate: {}
        )) {
            XCTAssertEqual($0 as? DisplayEnableTransactionError, .configurationFailed)
        }
        XCTAssertEqual(configureTrace, [
            lifecycleEvent(.enablePreValidationStarted), lifecycleEvent(.enablePreValidationFinished),
            lifecycleEvent(.enableBeginStarted), lifecycleEvent(.enableBeginFinished, .success),
            lifecycleEvent(.enableConfigureStarted), lifecycleEvent(.enableConfigureFinished, .failure),
            lifecycleEvent(.enableCancelStarted), lifecycleEvent(.enableCancelFinished, .success)
        ])
        XCTAssertEqual(configureFake.events, ["begin", "configure:42:true", "cancel"])

        let record = try makeRestoringRecord()
        let readFake = FakeCalls()
        var reads = 0
        var readTrace: [String] = []
        let readRecorder: DisplayEnableTransaction.Trace = { stage, status in
            readTrace.append(self.lifecycleEvent(stage, status))
        }
        XCTAssertThrowsError(try readFake.transaction().enableInternalForRecovery(
            record: record, loadRecord: { record }, trace: readRecorder,
            internalReader: { identity in
                reads += 1
                if reads == 3 { throw ValidationError.revoked }
                return self.internalState(identity: identity, hardwareIdentity: self.internalHardwareIdentity)
            }
        )) {
            XCTAssertEqual($0 as? ValidationError, .revoked)
        }
        XCTAssertEqual(readTrace, [
            lifecycleEvent(.enableIdentityReadStarted), lifecycleEvent(.enableIdentityReadFinished),
            lifecycleEvent(.enablePreValidationStarted),
            lifecycleEvent(.enableIdentityReadStarted), lifecycleEvent(.enableIdentityReadFinished),
            lifecycleEvent(.enablePreValidationFinished),
            lifecycleEvent(.enableBeginStarted), lifecycleEvent(.enableBeginFinished, .success),
            lifecycleEvent(.enableConfigureStarted), lifecycleEvent(.enableConfigureFinished, .success),
            lifecycleEvent(.enablePostValidationStarted), lifecycleEvent(.enableIdentityReadStarted),
            lifecycleEvent(.enableCancelStarted), lifecycleEvent(.enableCancelFinished, .success)
        ])
        XCTAssertEqual(readFake.events, ["begin", "configure:80:true", "cancel"])
    }

    func testEnableTraceRecordsCompleteFailureWithoutCancellingConsumedHandle() {
        let fake = FakeCalls()
        var traceEntries: [String] = []
        let trace: DisplayEnableTransaction.Trace = { stage, status in
            traceEntries.append(self.lifecycleEvent(stage, status))
        }

        XCTAssertThrowsError(try fake.transaction(completeResult: .failure).setEnabled(
            display: 42, enabled: true, trace: trace, validate: {}
        )) {
            XCTAssertEqual($0 as? DisplayEnableTransactionError, .commitFailed)
        }
        XCTAssertEqual(traceEntries, [
            lifecycleEvent(.enablePreValidationStarted), lifecycleEvent(.enablePreValidationFinished),
            lifecycleEvent(.enableBeginStarted), lifecycleEvent(.enableBeginFinished, .success),
            lifecycleEvent(.enableConfigureStarted), lifecycleEvent(.enableConfigureFinished, .success),
            lifecycleEvent(.enablePostValidationStarted), lifecycleEvent(.enablePostValidationFinished),
            lifecycleEvent(.enableCompleteStarted), lifecycleEvent(.enableCompleteFinished, .failure)
        ])
        XCTAssertEqual(fake.events, ["begin", "configure:42:true", "complete:\(CGConfigureOption.forSession.rawValue)"])
    }

    func testEnableTraceRecordsCancellationFailureAndPreservesOriginalError() {
        let fake = FakeCalls()
        var traceEntries: [String] = []
        let trace: DisplayEnableTransaction.Trace = { stage, status in
            traceEntries.append(self.lifecycleEvent(stage, status))
        }

        XCTAssertThrowsError(try fake.transaction(configureResult: .failure, cancelResult: .failure).setEnabled(
            display: 42, enabled: true, trace: trace, validate: {}
        )) {
            XCTAssertEqual($0 as? DisplayEnableTransactionError, .configurationFailed)
        }
        XCTAssertEqual(traceEntries, [
            lifecycleEvent(.enablePreValidationStarted), lifecycleEvent(.enablePreValidationFinished),
            lifecycleEvent(.enableBeginStarted), lifecycleEvent(.enableBeginFinished, .success),
            lifecycleEvent(.enableConfigureStarted), lifecycleEvent(.enableConfigureFinished, .failure),
            lifecycleEvent(.enableCancelStarted), lifecycleEvent(.enableCancelFinished, .failure)
        ])
        XCTAssertEqual(fake.events, ["begin", "configure:42:true", "cancel"])
    }

    func testRecoveryRejectsMissingOrCollidingBuiltInIdentityBeforeNativeCalls() throws {
        let applied = try layout(mainExternal: true)
        let cases: [(RecoveryRecord, Snapshot)] = [
            (try makeRestoringRecord(), makeSnapshot(applied, includeInternal: false)),
            (try makeRestoringRecord(), makeSnapshot(applied, externalDisplayID: 80))
        ]

        for (record, snapshot) in cases {
            let fake = FakeCalls()
            XCTAssertThrowsError(try fake.transaction().enableInternalForRecovery(
                record: record, loadRecord: { record },
                internalReader: { identity in try snapshot.internalDisplayState(identity: identity) }
            ))
            XCTAssertTrue(fake.events.isEmpty)
        }
    }

    func testRecoveryRejectsWrongUUIDNonBuiltInAndZeroInternalReadbackBeforeNativeCalls() throws {
        let record = try makeRestoringRecord()
        let invalidStates = [
            InternalDisplayState(id: 80, identityUUID: externalID, isBuiltIn: true, isOnline: true, isActive: false),
            InternalDisplayState(id: 80, identityUUID: internalID, isBuiltIn: false, isOnline: true, isActive: false),
            InternalDisplayState(id: 80, identityUUID: internalID, isBuiltIn: true, isOnline: false, isActive: false,
                                 hardwareIdentity: InternalDisplayHardwareIdentity(bootSession: session, registryEntryID: 999),
                                 reportedIdentityUUID: internalID),
            InternalDisplayState(id: 0, identityUUID: internalID, isBuiltIn: true, isOnline: true, isActive: false)
        ]

        for invalidState in invalidStates {
            let fake = FakeCalls()
            XCTAssertThrowsError(try fake.transaction().enableInternalForRecovery(
                record: record, loadRecord: { record }, internalReader: { _ in invalidState }
            )) { error in
                guard let recoveryError = error as? RecoveryError,
                      case .identityConflict = recoveryError else {
                    XCTFail("expected identityConflict, got \(error)")
                    return
                }
            }
            XCTAssertTrue(fake.events.isEmpty)
        }
    }

    private func runDisable(
        _ transaction: DisplayEnableTransaction,
        record: RecoveryRecord,
        storedRecord: () throws -> RecoveryRecord?,
        snapshotReader: () throws -> Snapshot,
        lidIsOpen: () -> Bool = { true },
        internalReader: ((UUID) throws -> InternalDisplayState)? = nil,
        checkProtection: (RecoveryRecord) throws -> Void
    ) throws {
        try transaction.disableInternal(
            record: record,
            loadRecord: storedRecord,
            snapshotReader: snapshotReader,
            lidIsOpen: lidIsOpen,
            checkProtection: checkProtection,
            internalReader: internalReader ?? { [self] identity in
                self.internalState(identity: identity, hardwareIdentity: self.internalHardwareIdentity)
            }
        )
    }

    private func readyProtection(for record: RecoveryRecord) throws -> ProtectionAuthorization {
        let handshake = try ProtectionHandshake(
            session: record.session, generation: record.generation, parentPID: 42,
            internalDisplayIdentity: record.internalDisplay?.identity,
            internalDisplayHardwareIdentity: record.internalDisplay?.hardwareIdentity
        )
        var protection = ProtectionAuthorization()
        try protection.acknowledge(receipt: handshake, expected: handshake)
        return protection
    }

    private func makeRecord(
        session: UUID? = nil,
        internalIdentity: UUID? = nil,
        internalBaseline: Bool = true,
        internalApplied: Bool = false,
        applying: Bool = true,
        includeResponsibility: Bool = true,
        includeHardwareIdentity: Bool = true
    ) throws -> RecoveryRecord {
        var record = try RecoveryRecord(
            session: session ?? self.session,
            baseline: layout(),
            target: layout(mainExternal: true),
            internalDisplay: includeResponsibility ? InternalDisplayResponsibility(
                identity: internalIdentity ?? internalID,
                baseline: internalBaseline,
                applied: internalApplied,
                hardwareIdentity: includeHardwareIdentity ? internalHardwareIdentity : nil
            ) : nil
        )
        if applying { try record.markApplying() }
        return record
    }

    private func makeRestoringRecord(sourceUnresolved: Bool = false) throws -> RecoveryRecord {
        var record = try makeRecord()
        try record.confirmApplied(try externalOnlyLayout(), internalEnabled: false)
        if sourceUnresolved {
            let unknownLayout = try layout(mainExternal: true, internalX: -1900)
            XCTAssertThrowsError(try record.observe(unknownLayout, source: .unknown))
        }
        record.beginRestoration()
        return record
    }

    private func makeNewerApplyingRecord() throws -> RecoveryRecord {
        var record = try makeRecord()
        let target = try layout(mainExternal: true)
        try record.confirmApplied(try externalOnlyLayout(), internalEnabled: false)
        try record.prepareReapplication(current: try externalOnlyLayout(), target: target)
        try record.markApplying()
        return record
    }

    private func makeUnresolvedApplyingRecord() throws -> RecoveryRecord {
        var record = try makeRecord()
        let target = try layout(mainExternal: true)
        try record.confirmApplied(try externalOnlyLayout(), internalEnabled: false)
        try record.prepareReapplication(current: try externalOnlyLayout(), target: target)
        try record.markApplying()
        try record.observe(layout(mainExternal: true, internalX: -1900), source: .unknown)
        XCTAssertTrue(record.sourceUnresolved)
        return record
    }

    private func layout(mainExternal: Bool = false, internalX: Int32? = nil) throws -> DisplayLayout {
        try DisplayLayout(main: mainExternal ? externalID : internalID, origins: [
            internalID: DisplayOrigin(x: mainExternal ? (internalX ?? -1728) : 0, y: 0),
            externalID: DisplayOrigin(x: mainExternal ? 0 : 1728, y: 0)
        ])
    }

    private func externalOnlyLayout() throws -> DisplayLayout {
        try DisplayLayout(main: externalID, origins: [externalID: DisplayOrigin(x: 0, y: 0)])
    }

    private func makeSnapshot(
        _ layout: DisplayLayout,
        includeInternal: Bool = true,
        internalActive: Bool = true,
        includeExternal: Bool = true,
        externalIdentity: DisplayIdentity = .physical,
        internalDisplayID: UInt32 = 80,
        externalDisplayID: UInt32 = 40
    ) -> Snapshot {
        var displays: [DisplayState] = []
        if includeInternal {
            displays.append(makeDisplay(
                id: internalDisplayID, identity: .builtIn, uuid: internalID, layout: layout, isActive: internalActive
            ))
        }
        if includeExternal {
            displays.append(makeDisplay(id: externalDisplayID, identity: externalIdentity, uuid: externalID, layout: layout))
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

    private func internalState(
        identity: UUID,
        hardwareIdentity: InternalDisplayHardwareIdentity
    ) -> InternalDisplayState {
        InternalDisplayState(
            id: 80, identityUUID: identity, isBuiltIn: true, isOnline: true, isActive: true,
            hardwareIdentity: hardwareIdentity, reportedIdentityUUID: identity
        )
    }

    private func lifecycleEvent(_ stage: InternalLifecycleStage, _ status: CGError? = nil) -> String {
        "\(stage.rawValue):\(status.map { String($0.rawValue) } ?? "nil")"
    }
}
