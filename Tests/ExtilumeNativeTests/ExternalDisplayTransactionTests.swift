import CoreGraphics
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class ExternalDisplayTransactionTests: XCTestCase {
    let internalID = UUID()
    let externalID = UUID()
    var identity: ExternalDisplayIdentity {
        ExternalDisplayIdentity(uuid: externalID, registryPath: "IOService:/test-hdmi", edidUUID: "test-edid",
                                bootSession: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!, registryEntryID: 7)
    }
    func layout() throws -> DisplayLayout {
        try DisplayLayout(main: externalID, origins: [externalID: DisplayOrigin(x: 0, y: 0),
                                                       internalID: DisplayOrigin(x: -100, y: 0)])
    }
    func snapshot(_ layout: DisplayLayout, internalActive: Bool = true) -> Snapshot {
        Snapshot(displays: layout.origins.map { uuid, position in
            DisplayState(id: uuid == internalID ? 1 : 2, identity: uuid == internalID ? .builtIn : .physical,
                         identityUUID: uuid, isOnline: true, isActive: uuid == internalID ? internalActive : true,
                         isMain: uuid == layout.main, isMirrored: false,
                         originX: CGFloat(position.x), originY: CGFloat(position.y), width: 100, height: 100, rotation: 0,
                         mode: DisplayModeState(width: 100, height: 100, pixelWidth: 100, pixelHeight: 100,
                                                refreshRate: 60, ioDisplayModeID: 1))
        }.sorted { $0.id < $1.id })
    }
    func record() throws -> RecoveryRecord {
        var record = try RecoveryRecord(baseline: layout(), target: layoutByMakingMain(layout(), target: internalID),
                                        externalDisplay: ExternalDisplayResponsibility(identity: identity, numericIDHint: 2,
                                                                                       baseline: true, applied: false))
        try record.markApplying()
        return record
    }
    var state: ExternalDisplayState { ExternalDisplayState(id: 2, identity: identity, isOnline: true, isActive: true) }

    final class Fake {
        let token = NSObject()
        var events: [String] = []
        var completeResult: CGError = .success
        var originResult: CGError = .success
        var afterConfigure: () -> Void = {}
        func transaction() -> DisplayEnableTransaction {
            DisplayEnableTransaction(configure: { _, id, enabled in
                self.events.append("enable:\(id):\(enabled)"); self.afterConfigure(); return .success
            }, begin: { pointer in
                self.events.append("begin")
                pointer.pointee = unsafeBitCast(Unmanaged.passUnretained(self.token).toOpaque(), to: CGDisplayConfigRef.self)
                return .success
            }, complete: { _, option in
                self.events.append("complete:\(option.rawValue)"); return self.completeResult
            }, cancel: { _ in self.events.append("cancel"); return .success }, origin: { _, id, x, y in
                self.events.append("origin:\(id):\(x):\(y)"); return self.originResult
            })
        }
    }

    func testDisableStagesInternalMainAndExternalDisableInOneCommit() throws {
        let record = try record(), current = snapshot(try layout()), fake = Fake()
        try fake.transaction().disableExternal(record: record, loadRecord: { record }, snapshotReader: { current },
                                               externalReader: { self.state }, lidIsOpen: { true }, checkAccess: {})
        XCTAssertEqual(fake.events, ["begin", "origin:1:0:0", "origin:2:100:0", "enable:2:false",
                                     "complete:\(CGConfigureOption.forAppOnly.rawValue)"])
    }

    func testLidInternalAvailabilityAndOldResponsibilityPreventBegin() throws {
        let record = try record()
        for scenario in 0..<4 {
            let fake = Fake()
            XCTAssertThrowsError(try fake.transaction().disableExternal(
                record: record, loadRecord: { scenario == 2 ? nil : record },
                snapshotReader: { self.snapshot(try self.layout(), internalActive: scenario != 1) },
                externalReader: { self.state }, lidIsOpen: { scenario != 0 }, checkAccess: { if scenario == 3 { throw RecoveryError.invalidTransition } }))
            XCTAssertTrue(fake.events.isEmpty)
        }
    }

    func testRevocationBeforeCommitCancelsAndCommitFailureConsumesHandle() throws {
        let record = try record(), current = snapshot(try layout())
        let fake = Fake()
        var revoked = false
        fake.afterConfigure = { revoked = true }
        XCTAssertThrowsError(try fake.transaction().disableExternal(
            record: record, loadRecord: { record }, snapshotReader: { current }, externalReader: { self.state },
            lidIsOpen: { true }, checkAccess: { if revoked { throw RecoveryError.invalidTransition } }))
        XCTAssertEqual(fake.events.last, "cancel")
        XCTAssertFalse(fake.events.contains { $0.hasPrefix("complete") })
        let failed = Fake(); failed.completeResult = .failure
        XCTAssertThrowsError(try failed.transaction().disableExternal(
            record: record, loadRecord: { record }, snapshotReader: { current }, externalReader: { self.state },
            lidIsOpen: { true }, checkAccess: {}))
        XCTAssertFalse(failed.events.contains("cancel"))
        let originFailed = Fake(); originFailed.originResult = .failure
        XCTAssertThrowsError(try originFailed.transaction().disableExternal(
            record: record, loadRecord: { record }, snapshotReader: { current }, externalReader: { self.state },
            lidIsOpen: { true }, checkAccess: {}))
        XCTAssertEqual(originFailed.events.last, "cancel")
        XCTAssertFalse(originFailed.events.contains("enable:2:false"))
    }

    func testRecoveryChecksOriginalIdentityAndKeepsFailedHandleConsumed() throws {
        var record = try record(); record.beginRestoration()
        let restoring = record, fake = Fake()
        fake.completeResult = .failure
        XCTAssertThrowsError(try fake.transaction().enableExternalForRecovery(
            record: restoring, loadRecord: { restoring }, externalReader: { self.state }))
        XCTAssertFalse(fake.events.contains("cancel"))
        let wrong = Fake()
        XCTAssertThrowsError(try wrong.transaction().enableExternalForRecovery(
            record: restoring, loadRecord: { restoring }, externalReader: {
                ExternalDisplayState(id: 3, identity: ExternalDisplayIdentity(uuid: UUID(), registryPath: "other",
                    edidUUID: "other", bootSession: self.identity.bootSession, registryEntryID: 9), isOnline: true, isActive: true)
            }))
        XCTAssertTrue(wrong.events.isEmpty)
    }

    func testExplicitWriteFlagRequiredAndStatusReadOnly() throws {
        XCTAssertNil(try ExternalVerificationCommand(arguments: []))
        XCTAssertEqual(try ExternalVerificationCommand(arguments: ["--external-status", "/tmp/state"]), .status("/tmp/state"))
        for flag in ["--verify-external-disable", "--recover-external"] {
            XCTAssertThrowsError(try ExternalVerificationCommand(arguments: [flag, "/tmp/state"]))
            XCTAssertThrowsError(try ExternalVerificationCommand(arguments: [flag, "--allow-display-write"]))
            XCTAssertThrowsError(try ExternalVerificationCommand(arguments: [flag, "wrong", "/tmp/state"]))
        }
        XCTAssertEqual(try ExternalVerificationCommand(arguments: ["--verify-external-disable", "--allow-display-write", "/tmp/state"]), .disable("/tmp/state"))
    }

    func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    func testStatusNeverWritesAndAbsentTargetIsNotDisabledSuccess() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let record = try record()
        do { let store = try RecoveryStore(directory: directory); try store.acquireExclusiveOwnership(); try store.save(record) }
        let data = try Data(contentsOf: directory.appendingPathComponent("recovery-record.json"))
        var writes = 0
        let verifier = try ExternalDisplayVerification(directory: directory, snapshot: { self.snapshot(try self.layout()) }, topology: { self.snapshot(try self.layout()) },
            external: { _, _ in throw RecoveryError.identityConflict },
            transaction: { writes += 1; return Fake().transaction() }, writeOrigins: { _, _ in writes += 1 })
        XCTAssertThrowsError(try verifier.status())
        XCTAssertEqual(writes, 0)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("recovery-record.json")), data)
    }

    func testPrototypeRoundTripPreservesCAndRetainsSettledRecord() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let before = snapshot(baseline)
        let internalMain = try layoutByMakingMain(baseline, target: internalID)
        let onlyInternal = try DisplayLayout(main: internalID, origins: [internalID: DisplayOrigin(x: 0, y: 0)])
        var current = before
        var enabled = true
        var stagedEnabled = true
        var writes = 0
        let token = NSObject()
        let verifier = try ExternalDisplayVerification(directory: directory, snapshot: { current }, topology: { current },
            external: { _, _ in ExternalDisplayState(id: 2, identity: self.identity, isOnline: true, isActive: enabled) },
            capture: { _ in self.state }, lidIsOpen: { true }, transaction: {
                DisplayEnableTransaction(configure: { _, _, value in stagedEnabled = value; return .success },
                    begin: { $0.pointee = unsafeBitCast(Unmanaged.passUnretained(token).toOpaque(), to: CGDisplayConfigRef.self); return .success },
                    complete: { _, _ in
                        writes += 1
                        enabled = stagedEnabled
                        current = self.snapshot(enabled ? internalMain : onlyInternal)
                        return .success
                    }, cancel: { _ in .success }, origin: { _, _, _, _ in .success })
            }, writeOrigins: { origins, validate in
                try validate()
                XCTAssertEqual(origins[1], baseline.origins[self.internalID])
                XCTAssertEqual(origins[2], baseline.origins[self.externalID])
                writes += 1
                current = before
            })
        try verifier.disable()
        let store = try RecoveryStore(directory: directory)
        let owned = try XCTUnwrap(store.load())
        XCTAssertEqual(owned.baseline, baseline)
        XCTAssertEqual(owned.applied, onlyInternal)
        XCTAssertTrue(owned.requiresRecovery)
        var commands = ["status", "invalid", "restore"]
        var messages: [String] = []
        try holdExternalVerification(verifier, readCommand: { commands.isEmpty ? nil : commands.removeFirst() },
                                     output: { messages.append($0) })
        XCTAssertTrue(commands.isEmpty)
        XCTAssertEqual(messages.count, 3)
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.baseline, baseline)
        XCTAssertTrue(restored.canClear)
        XCTAssertEqual(writes, 3)
        try verifier.restore()
        XCTAssertEqual(writes, 3)
    }

    func testRestoredLayoutChangeRequiresConfirmationAndPersistsNewC() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try layout()
        let userC = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 2048, y: 200)
        ])
        let internalOnly = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0)
        ])
        var settled = try record()
        try settled.confirmApplied(internalOnly, internalEnabled: true, externalEnabled: false)
        settled.beginRestoration()
        try settled.confirmRestored(actual: baseline, internalEnabled: true, externalEnabled: true)

        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        try store.save(settled)
        let current = snapshot(userC)
        var originWrites = 0
        let verifier = try ExternalDisplayVerification(
            directory: directory, recoveryStore: store,
            snapshot: { current }, topology: { current },
            external: { _, _ in self.state },
            transaction: { XCTFail("enabled target needs no display transaction"); return Fake().transaction() },
            writeOrigins: { _, _ in originWrites += 1 }
        )

        XCTAssertThrowsError(try verifier.restore()) { error in
            guard case RecoveryError.unresolvedSource = error else {
                return XCTFail("Expected unresolvedSource, got \(error)")
            }
        }
        XCTAssertEqual(try store.load(), settled)
        XCTAssertTrue(try XCTUnwrap(store.load()).canClear)

        try verifier.confirmUserLayout()
        let confirmed = try XCTUnwrap(store.load())
        XCTAssertEqual(confirmed.baseline, userC)
        XCTAssertEqual(confirmed.phase, .owned)
        XCTAssertFalse(confirmed.canClear)
        XCTAssertFalse(confirmed.externalDisplay?.pending ?? true)

        try verifier.restore()
        let restored = try XCTUnwrap(store.load())
        XCTAssertEqual(restored.baseline, userC)
        XCTAssertTrue(restored.canClear)
        XCTAssertEqual(originWrites, 0)
    }

    func testPrototypeUnconfirmedTargetKeepsResponsibilityWhenCompensationFails() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        var reads = 0
        let fake = Fake()
        let verifier = try ExternalDisplayVerification(directory: directory,
            snapshot: { self.snapshot(try self.layout()) }, topology: { self.snapshot(try self.layout()) },
            external: { _, _ in
                reads += 1
                if reads > 3 { throw RecoveryError.identityConflict }
                return self.state
            }, capture: { _ in self.state }, lidIsOpen: { true }, transaction: { fake.transaction() },
            writeOrigins: { _, _ in XCTFail("unconfirmed target must not write layout") })
        XCTAssertThrowsError(try verifier.disable())
        let record = try XCTUnwrap(RecoveryStore(directory: directory).load())
        XCTAssertTrue(record.requiresRecovery)
        XCTAssertFalse(record.canClear)
        XCTAssertEqual(record.baseline, try layout())
    }

    func testUnresolvedResultCanSettleOnlyWithIndependentCompleteBaseline() throws {
        for isBaseline in [true, false] {
            let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
            var unresolved = try record()
            XCTAssertThrowsError(try unresolved.confirmApplied(try layout(), internalEnabled: true, externalEnabled: true))
            XCTAssertTrue(unresolved.sourceUnresolved)
            do { let store = try RecoveryStore(directory: directory); try store.acquireExclusiveOwnership(); try store.save(unresolved) }
            let actual = isBaseline ? try layout() : try layoutByMakingMain(layout(), target: internalID)
            let verifier = try ExternalDisplayVerification(directory: directory, snapshot: { self.snapshot(actual) }, topology: { self.snapshot(actual) },
                external: { _, _ in self.state }, transaction: { XCTFail("already enabled"); return Fake().transaction() },
                writeOrigins: { _, _ in XCTFail("must not write unresolved configuration") })
            if isBaseline { try verifier.restore() }
            else { XCTAssertThrowsError(try verifier.restore()) }
            let stored = try XCTUnwrap(RecoveryStore(directory: directory).load())
            XCTAssertEqual(stored.canClear, isBaseline)
            XCTAssertEqual(stored.baseline, try layout())
        }
    }

    func testOnlineInactiveThirdDisplayPreventsEntryWithoutRecordingOrWriting() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let active = snapshot(try layout())
        let extra = DisplayState(id: 3, identity: .physical, identityUUID: UUID(), isOnline: true, isActive: false,
            isMain: false, isMirrored: false, originX: 0, originY: 0, width: 100, height: 100, rotation: 0,
            mode: active.displays[0].mode)
        let full = Snapshot(displays: active.displays + [extra])
        let verifier = try ExternalDisplayVerification(directory: directory, snapshot: { active }, topology: { full },
            capture: { _ in XCTFail("unsupported topology"); return self.state },
            transaction: { XCTFail("unsupported topology"); return Fake().transaction() })
        XCTAssertThrowsError(try verifier.disable())
        XCTAssertNil(try RecoveryStore(directory: directory).load())
        let fake = Fake(), record = try record()
        XCTAssertThrowsError(try fake.transaction().disableExternal(record: record, loadRecord: { record },
            snapshotReader: { full }, externalReader: { self.state }, lidIsOpen: { true }, checkAccess: {}))
        XCTAssertTrue(fake.events.isEmpty)
    }

    func testLegacyGuardHandshakeCannotAcceptExternalRecord() throws {
        let record = try record()
        let handshake = try ProtectionHandshake(session: record.session, generation: record.generation, parentPID: 42)
        XCTAssertFalse(handshake.accepts(record: record))
    }

    func testLegacyPrimaryRecoveryRefusesExternalResponsibility() throws {
        let directory = try directory(); defer { try? FileManager.default.removeItem(at: directory) }
        let record = try record()
        do { let store = try RecoveryStore(directory: directory); try store.acquireExclusiveOwnership(); try store.save(record) }
        let controller = try PrimaryController(directory: directory, snapshotReader: { throw RecoveryError.invalidRecord },
                                               originWriter: { _, _ in XCTFail("must not write") })
        XCTAssertThrowsError(try controller.recoverOnly())
        XCTAssertEqual(try RecoveryStore(directory: directory).load(), record)
    }
}
