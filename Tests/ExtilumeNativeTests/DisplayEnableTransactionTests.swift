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
                    return .success
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

    func testRecoveryEnablesBuiltInWithoutExternalOrReadyProtectionAndLeavesRecordAlone() throws {
        let record = try makeRestoringRecord(sourceUnresolved: true)
        let snapshot = makeSnapshot(try layout(mainExternal: true), internalActive: false, includeExternal: false)
        let fake = FakeCalls()

        try fake.transaction().enableInternalForRecovery(
            record: record, loadRecord: { record }, snapshotReader: { snapshot }
        )

        XCTAssertEqual(fake.events, [
            "begin", "configure:80:true", "complete:\(CGConfigureOption.forSession.rawValue)"
        ])
        XCTAssertEqual(record.phase, .restoring)
        XCTAssertTrue(record.sourceUnresolved)
        XCTAssertTrue(record.internalDisplay?.pending == true)
    }

    func testRecoveryRejectsMissingWrongOrCollidingBuiltInIdentityBeforeNativeCalls() throws {
        let applied = try layout(mainExternal: true)
        let cases: [(RecoveryRecord, Snapshot)] = [
            (try makeRestoringRecord(), makeSnapshot(applied, includeInternal: false)),
            (try makeRestoringRecord(internalIdentity: externalID), makeSnapshot(applied)),
            (try makeRestoringRecord(), makeSnapshot(applied, externalDisplayID: 80))
        ]

        for (record, snapshot) in cases {
            let fake = FakeCalls()
            XCTAssertThrowsError(try fake.transaction().enableInternalForRecovery(
                record: record, loadRecord: { record }, snapshotReader: { snapshot }
            ))
            XCTAssertTrue(fake.events.isEmpty)
        }
    }

    private func runDisable(
        _ transaction: DisplayEnableTransaction,
        record: RecoveryRecord,
        storedRecord: () throws -> RecoveryRecord?,
        snapshotReader: () throws -> Snapshot,
        lidIsOpen: () -> Bool = { true },
        checkProtection: (RecoveryRecord) throws -> Void
    ) throws {
        try transaction.disableInternal(
            record: record,
            loadRecord: storedRecord,
            snapshotReader: snapshotReader,
            lidIsOpen: lidIsOpen,
            checkProtection: checkProtection
        )
    }

    private func readyProtection(for record: RecoveryRecord) throws -> ProtectionAuthorization {
        let handshake = try ProtectionHandshake(
            session: record.session, generation: record.generation, parentPID: 42,
            internalDisplayIdentity: record.internalDisplay?.identity
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
        includeResponsibility: Bool = true
    ) throws -> RecoveryRecord {
        var record = try RecoveryRecord(
            session: session ?? self.session,
            baseline: layout(),
            target: layout(mainExternal: true),
            internalDisplay: includeResponsibility ? InternalDisplayResponsibility(
                identity: internalIdentity ?? internalID,
                baseline: internalBaseline,
                applied: internalApplied
            ) : nil
        )
        if applying { try record.markApplying() }
        return record
    }

    private func makeRestoringRecord(
        internalIdentity: UUID? = nil,
        sourceUnresolved: Bool = false
    ) throws -> RecoveryRecord {
        var record = try makeRecord(internalIdentity: internalIdentity)
        try record.confirmApplied(try layout(mainExternal: true), internalEnabled: false)
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
        try record.confirmApplied(target, internalEnabled: false)
        try record.prepareReapplication(current: target, target: target)
        try record.markApplying()
        return record
    }

    private func makeUnresolvedApplyingRecord() throws -> RecoveryRecord {
        var record = try makeRecord()
        let target = try layout(mainExternal: true)
        try record.confirmApplied(target, internalEnabled: false)
        try record.prepareReapplication(current: target, target: target)
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
}
