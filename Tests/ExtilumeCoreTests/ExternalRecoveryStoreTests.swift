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
