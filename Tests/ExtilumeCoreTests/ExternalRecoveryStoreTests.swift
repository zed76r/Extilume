import Darwin
import Foundation
import XCTest
@testable import ExtilumeCore

final class ExternalRecoveryStoreTests: XCTestCase {
    private let internalID = UUID(uuidString: "20000000-0000-4000-8000-000000000001")!
    private let externalID = UUID(uuidString: "20000000-0000-4000-8000-000000000002")!

    func testExternalApplyPersistsResponsibilityBeforeOperationAndConfirmsResult() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let fixture = try makeFixture()
            let owned = try store.applyExternal(fixture.prepared) {
                let persisted = try XCTUnwrap(store.load())
                XCTAssertEqual(persisted.phase, .applying)
                XCTAssertEqual(persisted.externalDisplay, fixture.prepared.externalDisplay)
                return (fixture.internalOnly, true, false)
            }

            XCTAssertEqual(owned.phase, .owned)
            XCTAssertEqual(owned.applied, fixture.internalOnly)
            XCTAssertEqual(owned.preDisableLayout, fixture.target)
            XCTAssertTrue(owned.externalDisplay?.pending == true)
            XCTAssertEqual(try store.load(), owned)
        }
    }

    func testExternalOperationFailureLeavesApplyingResponsibility() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let fixture = try makeFixture()
            var operationCalled = false

            XCTAssertThrowsError(try store.applyExternal(fixture.prepared) {
                operationCalled = true
                throw RecoveryStoreError.ioFailure
            }) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .ioFailure)
            }

            XCTAssertTrue(operationCalled)
            let applying = try XCTUnwrap(store.load())
            XCTAssertEqual(applying.phase, .applying)
            XCTAssertTrue(applying.externalDisplay?.pending == true)
            XCTAssertEqual(applying.applied, fixture.target)
            XCTAssertNil(applying.preDisableLayout)
            XCTAssertFalse(applying.canClear)
        }
    }

    func testExternalConfirmationFailurePersistsUnresolvedResponsibility() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let fixture = try makeFixture()

            XCTAssertThrowsError(try store.applyExternal(fixture.prepared) {
                (fixture.target, true, false)
            }) { error in
                XCTAssertEqual(error as? RecoveryError, .unresolvedSource)
            }

            let applying = try XCTUnwrap(store.load())
            XCTAssertEqual(applying.phase, .applying)
            XCTAssertTrue(applying.sourceUnresolved)
            XCTAssertTrue(applying.externalDisplay?.pending == true)
            XCTAssertFalse(applying.canClear)
        }
    }

    func testPrimaryApplyRejectsExternalResponsibilityBeforeWritingOrOperating() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let fixture = try makeFixture()
            var operationCalled = false

            XCTAssertThrowsError(try store.apply(fixture.prepared) {
                operationCalled = true
                return (fixture.internalOnly, true)
            }) { error in
                XCTAssertEqual(error as? RecoveryError, .invalidRecord)
            }

            XCTAssertFalse(operationCalled)
            XCTAssertNil(try store.load())
        }
    }

    func testExternalFinalSaveFailureLeavesApplyingRecordOnDisk() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let fixture = try makeFixture()
            let url = recordURL(in: directory)
            defer { _ = chmod(url.path, mode_t(0o600)) }
            var applyingBeforeOperation: RecoveryRecord?

            XCTAssertThrowsError(try store.applyExternal(fixture.prepared) {
                applyingBeforeOperation = try store.load()
                XCTAssertEqual(applyingBeforeOperation?.phase, .applying)
                XCTAssertEqual(chmod(url.path, mode_t(0o400)), 0)
                return (fixture.internalOnly, true, false)
            }) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .unsafeRecordFile)
            }

            XCTAssertEqual(chmod(url.path, mode_t(0o600)), 0)
            let applying = try XCTUnwrap(store.load())
            XCTAssertEqual(applying.phase, .applying)
            XCTAssertEqual(applying, applyingBeforeOperation)
            XCTAssertTrue(applying.externalDisplay?.pending == true)
        }
    }

    func testExternalCloseoutPreservesOriginalBindingAndSupportsRestoring() throws {
        let fixture = try makeFixture()
        var owned = fixture.prepared
        try owned.markApplying()
        try owned.confirmApplied(fixture.internalOnly, internalEnabled: true, externalEnabled: false)
        let old = try XCTUnwrap(owned.externalDisplay)
        let identity = newIdentity(old.identity)
        for restoring in [false, true] {
            var record = owned
            if restoring { record.beginRestoration() }
            let closed = try record.confirmingExternalCloseout(actual: fixture.baseline, identity: identity)
            XCTAssertEqual(closed.phase, .restored)
            XCTAssertTrue(closed.canClear)
            XCTAssertEqual(closed.session, record.session)
            XCTAssertEqual(closed.generation, record.generation)
            XCTAssertEqual(closed.externalDisplay?.identity, old.identity)
            XCTAssertEqual(closed.externalDisplay?.numericIDHint, old.numericIDHint)
            XCTAssertFalse(try XCTUnwrap(closed.externalDisplay).pending)
            XCTAssertFalse(closed.layoutPending)
        }
        XCTAssertThrowsError(try owned.confirmingLayoutCloseout(actual: fixture.baseline))
    }

    func testExternalCloseoutRejectsWrongIdentityLayoutPhaseAndUnresolved() throws {
        let fixture = try makeFixture()
        var owned = fixture.prepared
        try owned.markApplying()
        try owned.confirmApplied(fixture.internalOnly, internalEnabled: true, externalEnabled: false)
        let original = try XCTUnwrap(owned.externalDisplay).identity
        let current = newIdentity(original)
        let variants = [original,
            ExternalDisplayIdentity(uuid: UUID(), registryPath: original.registryPath, edidUUID: original.edidUUID, bootSession: current.bootSession, registryEntryID: 1),
            ExternalDisplayIdentity(uuid: original.uuid, registryPath: "other", edidUUID: original.edidUUID, bootSession: current.bootSession, registryEntryID: 1),
            ExternalDisplayIdentity(uuid: original.uuid, registryPath: original.registryPath, edidUUID: "other", bootSession: current.bootSession, registryEntryID: 1),
            ExternalDisplayIdentity(uuid: original.uuid, registryPath: original.registryPath, edidUUID: original.edidUUID, bootSession: current.bootSession, registryEntryID: 0)]
        for identity in variants {
            XCTAssertThrowsError(try owned.confirmingExternalCloseout(actual: fixture.baseline, identity: identity))
        }
        XCTAssertThrowsError(try owned.confirmingExternalCloseout(actual: fixture.target, identity: current))
        XCTAssertThrowsError(try fixture.prepared.confirmingExternalCloseout(actual: fixture.baseline, identity: current))
        var unresolved = owned
        XCTAssertThrowsError(try unresolved.observeExternalEnabled(true, source: .unknown))
        XCTAssertThrowsError(try unresolved.confirmingExternalCloseout(actual: fixture.baseline, identity: current))
        let noExternal = try RecoveryRecord(baseline: fixture.baseline, target: fixture.target)
        XCTAssertThrowsError(try noExternal.confirmingExternalCloseout(actual: fixture.baseline, identity: current))
        let internalResponsibility = InternalDisplayResponsibility(identity: internalID, baseline: true, applied: true)
        let mixed = try RecoveryRecord(baseline: fixture.baseline, target: fixture.target,
                                       internalDisplay: internalResponsibility, externalDisplay: fixture.prepared.externalDisplay)
        XCTAssertThrowsError(try mixed.confirmingExternalCloseout(actual: fixture.baseline, identity: current))
    }

    func testExternalCloseoutRequiresLockAndPreservesBytesAcrossFailures() throws {
        for failure in 0...5 {
            try withTemporaryDirectory { directory in
                let fixture = try makeFixture()
                let store = try RecoveryStore(directory: directory)
                try store.acquireExclusiveOwnership()
                let owned = try store.applyExternal(fixture.prepared) { (fixture.internalOnly, true, false) }
                let identity = newIdentity(try XCTUnwrap(owned.externalDisplay).identity)
                let original = try XCTUnwrap(store.loadWithOriginalBytes()?.bytes)
                let other = try RecoveryStore(directory: directory)
                XCTAssertThrowsError(try other.closeExternalResponsibility(expectedOriginal: original, target: fixture.baseline,
                    identity: identity, backup: { _ in }, verify: {}, beforeSave: {}))
                var backup: Data?
                var verifies = 0
                let changed = original + Data(" ".utf8)
                let run = {
                    try store.closeExternalResponsibility(expectedOriginal: failure == 0 ? changed : original,
                        target: fixture.baseline, identity: identity, backup: { bytes in
                            backup = bytes
                            if failure == 1 { throw RecoveryStoreError.ioFailure }
                        }, verify: {
                            verifies += 1
                            if failure == 2 && verifies == 2 { throw RecoveryStoreError.ioFailure }
                        }, beforeSave: {
                            if failure == 3 { try changed.write(to: self.recordURL(in: directory)) }
                        }, checkBeforeCommit: {
                            if failure == 4 { throw RecoveryStoreError.ioFailure }
                        })
                }
                if failure < 5 {
                    XCTAssertThrowsError(try run())
                    XCTAssertEqual(try store.loadWithOriginalBytes()?.bytes, failure == 3 ? changed : original)
                } else {
                    let closed = try run()
                    XCTAssertEqual(backup, original)
                    XCTAssertEqual(verifies, 3)
                    XCTAssertEqual(try store.load(), closed)
                    XCTAssertTrue(closed.canClear)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL(in: directory).path))
                }
            }
        }
    }

    private func newIdentity(_ old: ExternalDisplayIdentity) -> ExternalDisplayIdentity {
        ExternalDisplayIdentity(uuid: old.uuid, registryPath: old.registryPath, edidUUID: old.edidUUID,
                                bootSession: UUID(), registryEntryID: old.registryEntryID + 1)
    }

    private func makeFixture() throws -> (
        prepared: RecoveryRecord,
        baseline: DisplayLayout,
        target: DisplayLayout,
        internalOnly: DisplayLayout
    ) {
        let baseline = try DisplayLayout(main: externalID, origins: [
            internalID: DisplayOrigin(x: -1920, y: 0),
            externalID: DisplayOrigin(x: 0, y: 0)
        ])
        let target = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 1920, y: 0)
        ])
        let internalOnly = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0)
        ])
        let identity = ExternalDisplayIdentity(
            uuid: externalID,
            registryPath: "IOService:/fixture/external-display",
            edidUUID: "fixture-edid-uuid",
            bootSession: UUID(uuidString: "20000000-0000-4000-8000-000000000003")!,
            registryEntryID: 84
        )
        let responsibility = ExternalDisplayResponsibility(
            identity: identity, numericIDHint: 40, baseline: true, applied: false
        )
        return (
            try RecoveryRecord(baseline: baseline, target: target, externalDisplay: responsibility),
            baseline,
            target,
            internalOnly
        )
    }

    private func recordURL(in directory: URL) -> URL {
        directory.appendingPathComponent("recovery-record.json")
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(
            fileURLWithPath: "/private/tmp/extilume-external-recovery-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        guard mkdir(directory.path, mode_t(0o700)) == 0 else {
            throw RecoveryStoreError.ioFailure
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
