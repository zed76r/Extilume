import Darwin
import Foundation
import XCTest
@testable import ExtilumeCore

final class RecoveryStoreTests: XCTestCase {
    private let mainIdentity = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
    private let outerIdentity = UUID(uuidString: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee")!

    func testStaleGenerationCannotReplaceNewerResponsibility() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            var newer = try makeRecord(pendingLayout: true)
            let old = newer
            try newer.confirmApplied(newer.applied)
            try newer.prepareReapplication(current: newer.applied, target: newer.applied)
            try store.save(newer)
            XCTAssertThrowsError(try store.save(old)) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .staleGeneration)
            }
            XCTAssertEqual(try store.load(), newer)
        }
    }

    func testSaveAndLoadUseRestrictedFileAndPreserveRecord() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let record = try makeRecord(pendingLayout: true)

            try store.save(record)

            XCTAssertEqual(try store.load(), record)
            var info = stat()
            XCTAssertEqual(lstat(recordURL(in: directory).path, &info), 0)
            XCTAssertEqual(info.st_uid, getuid())
            XCTAssertEqual(info.st_mode & mode_t(0o7777), mode_t(0o600))
            XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        }
    }

    func testRejectsInsecureOrSymlinkDirectory() throws {
        try withTemporaryDirectory { directory in
            XCTAssertEqual(chmod(directory.path, mode_t(0o755)), 0)
            XCTAssertThrowsError(try RecoveryStore(directory: directory)) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .insecureDirectory)
            }
        }

        try withTemporaryDirectory { target in
            let link = target.deletingLastPathComponent()
                .appendingPathComponent("extilume-recovery-link-\(UUID().uuidString)", isDirectory: true)
            defer { _ = unlink(link.path) }
            XCTAssertEqual(symlink(target.path, link.path), 0)
            XCTAssertThrowsError(try RecoveryStore(directory: link)) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .insecureDirectory)
            }
        }
    }

    func testRejectsSymlinkRecordWithoutFollowingOrReplacingIt() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let target = directory.appendingPathComponent("fixture.json")
            XCTAssertTrue(FileManager.default.createFile(atPath: target.path, contents: Data("fixture".utf8)))
            XCTAssertEqual(chmod(target.path, mode_t(0o600)), 0)
            XCTAssertEqual(symlink(target.path, recordURL(in: directory).path), 0)

            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .unsafeRecordFile)
            }
            XCTAssertThrowsError(try store.save(try makeRecord(pendingLayout: true))) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .unsafeRecordFile)
            }
            var info = stat()
            XCTAssertEqual(lstat(recordURL(in: directory).path, &info), 0)
            XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
            XCTAssertEqual(try Data(contentsOf: target), Data("fixture".utf8))
        }
    }

    func testRejectsMalformedPayloadAndDoesNotOverwriteIt() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let url = recordURL(in: directory)
            let malformed = Data("not-json".utf8)
            try malformed.write(to: url)
            XCTAssertEqual(chmod(url.path, mode_t(0o600)), 0)

            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .corruptRecord)
            }
            XCTAssertThrowsError(try store.save(try makeRecord(pendingLayout: false))) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .corruptRecord)
            }
            XCTAssertEqual(try Data(contentsOf: url), malformed)
        }
    }

    func testRejectsDecodedRecordThatFailsValidation() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            let validData = try JSONEncoder().encode(makeRecord(pendingLayout: false))
            var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
            payload["version"] = 2
            let invalidRecord = try JSONSerialization.data(withJSONObject: payload)
            let url = recordURL(in: directory)
            try invalidRecord.write(to: url)
            XCTAssertEqual(chmod(url.path, mode_t(0o600)), 0)

            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .corruptRecord)
            }
        }
    }

    func testRejectsRelaxedRecordPermissionsWithoutOverwriting() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let existing = try makeRecord(pendingLayout: true)
            try store.save(existing)
            let url = recordURL(in: directory)
            let originalData = try Data(contentsOf: url)
            XCTAssertEqual(chmod(url.path, mode_t(0o644)), 0)

            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .unsafeRecordFile)
            }
            XCTAssertThrowsError(try store.save(existing)) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .unsafeRecordFile)
            }
            XCTAssertEqual(try Data(contentsOf: url), originalData)
        }
    }

    func testRejectsNonRegularRecordWithoutReplacingIt() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let url = recordURL(in: directory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)

            XCTAssertThrowsError(try store.load()) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .unsafeRecordFile)
            }
            XCTAssertThrowsError(try store.save(try makeRecord(pendingLayout: true))) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .unsafeRecordFile)
            }
            var info = stat()
            XCTAssertEqual(lstat(url.path, &info), 0)
            XCTAssertEqual(info.st_mode & mode_t(S_IFMT), mode_t(S_IFDIR))
        }
    }

    func testClearRejectsUnfinishedAndPendingResponsibilities() throws {
        let prepared = try makeRecord(pendingLayout: false)
        var applying = try makeRecord(pendingLayout: false)
        try applying.markApplying()
        var restoring = try makeRecord(pendingLayout: false)
        restoring.beginRestoration()
        let pendingLayout = try makeRecord(pendingLayout: true)
        let pendingInternal = try makeRecord(pendingLayout: false, pendingInternal: true)
        for record in [prepared, applying, restoring, pendingLayout, pendingInternal] {
            try withTemporaryDirectory { directory in
                let store = try RecoveryStore(directory: directory)
                try store.acquireExclusiveOwnership()
                try store.save(record)
                XCTAssertFalse(record.canClear)
                XCTAssertThrowsError(try store.clear()) { error in
                    XCTAssertEqual(error as? RecoveryStoreError, .unresolvedResponsibility)
                }
                XCTAssertEqual(try store.load(), record)
            }
        }
    }

    func testDifferentSessionCannotReplacePendingResponsibility() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let existing = try makeRecord(
                pendingLayout: true,
                session: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
            )
            let next = try makeRecord(
                pendingLayout: false,
                session: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
            )
            try store.save(existing)

            XCTAssertThrowsError(try store.save(next)) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .differentSessionPending)
            }
            XCTAssertEqual(try store.load(), existing)
        }
    }

    func testConfirmedRecoveryCanBeClearedAndMissingRecordIsNoOp() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            XCTAssertNoThrow(try store.clear())

            var record = try makeRecord(pendingLayout: false)
            let baseline = try layout(otherX: 100)
            record.beginRestoration()
            try record.confirmRestored(actual: baseline)
            XCTAssertTrue(record.canClear)
            try store.save(record)
            try store.clear()
            XCTAssertNil(try store.load())
        }
    }

    func testApplicationCannotRunBeforeResponsibilityIsPersisted() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let prepared = try makeRecord(pendingLayout: true)
            let owned = try store.apply(prepared) {
                let saved = try XCTUnwrap(store.load())
                XCTAssertEqual(saved.phase, .applying)
                XCTAssertTrue(saved.layoutPending)
                return (prepared.applied, nil)
            }
            XCTAssertEqual(owned.phase, .owned)
            XCTAssertEqual(try store.load(), owned)
        }
    }

    func testExclusiveOwnershipRejectsSecondControllerAndReleasesOnExit() throws {
        try withTemporaryDirectory { directory in
            var owner: RecoveryStore? = try RecoveryStore(directory: directory)
            try owner?.acquireExclusiveOwnership()
            let other = try RecoveryStore(directory: directory)
            XCTAssertThrowsError(try other.acquireExclusiveOwnership())
            owner = nil
            XCTAssertNoThrow(try other.acquireExclusiveOwnership())
        }
    }

    func testFailedApplicationKeepsResponsibilityAndRejectsRetry() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            let prepared = try makeRecord(pendingLayout: true)
            XCTAssertThrowsError(try store.apply(prepared) {
                throw RecoveryStoreError.ioFailure
            })
            XCTAssertEqual(try store.load()?.phase, .applying)
            XCTAssertThrowsError(try store.clear())
            var invoked = false
            XCTAssertThrowsError(try store.apply(prepared) {
                invoked = true
                return (prepared.applied, nil)
            })
            XCTAssertFalse(invoked)
        }
    }

    func testUnownedStoreCannotSaveClearOrApply() throws {
        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            let record = try makeRecord(pendingLayout: true)

            XCTAssertThrowsError(try store.save(record)) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .ownershipUnavailable)
            }
            XCTAssertNil(try store.load())
        }

        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)

            XCTAssertThrowsError(try store.clear()) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .ownershipUnavailable)
            }
            XCTAssertNil(try store.load())
        }

        try withTemporaryDirectory { directory in
            let store = try RecoveryStore(directory: directory)
            let prepared = try makeRecord(pendingLayout: true)
            var operationInvoked = false

            XCTAssertThrowsError(try store.apply(prepared) {
                operationInvoked = true
                return (prepared.applied, nil)
            }) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .ownershipUnavailable)
            }
            XCTAssertFalse(operationInvoked)
            XCTAssertNil(try store.load())
        }
    }

    func testUnownedStoreCannotOverwriteOrClearOwnersRestoredRecord() throws {
        try withTemporaryDirectory { directory in
            let owner = try RecoveryStore(directory: directory)
            try owner.acquireExclusiveOwnership()

            var restored = try makeRecord(pendingLayout: false)
            restored.beginRestoration()
            try restored.confirmRestored(actual: restored.baseline)
            XCTAssertTrue(restored.canClear)
            try owner.save(restored)

            let originalBytes = try Data(contentsOf: recordURL(in: directory))
            let unowned = try RecoveryStore(directory: directory)
            XCTAssertThrowsError(try unowned.acquireExclusiveOwnership())
            XCTAssertEqual(try unowned.load(), restored)

            var newer = try makeRecord(pendingLayout: true, session: restored.session)
            try newer.confirmApplied(newer.applied)
            try newer.prepareReapplication(current: newer.applied, target: newer.applied)
            XCTAssertGreaterThan(newer.generation, restored.generation)

            XCTAssertThrowsError(try unowned.save(newer)) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .ownershipUnavailable)
            }
            XCTAssertEqual(try Data(contentsOf: recordURL(in: directory)), originalBytes)
            XCTAssertEqual(try unowned.load(), restored)

            XCTAssertThrowsError(try unowned.clear()) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .ownershipUnavailable)
            }
            XCTAssertEqual(try Data(contentsOf: recordURL(in: directory)), originalBytes)
            XCTAssertEqual(try unowned.load(), restored)

            try owner.clear()
            XCTAssertNil(try owner.load())
            XCTAssertNil(try unowned.load())
        }
    }

    private func makeRecord(
        pendingLayout: Bool,
        pendingInternal: Bool = false,
        session: UUID = UUID()
    ) throws -> RecoveryRecord {
        let baseline = try layout(otherX: 100)
        let target = try layout(otherX: pendingLayout ? -100 : 100)
        let responsibility = pendingInternal
            ? InternalDisplayResponsibility(identity: outerIdentity, baseline: false, applied: true)
            : nil
        return try RecoveryRecord(
            session: session,
            baseline: baseline,
            target: target,
            internalDisplay: responsibility
        )
    }

    private func layout(otherX: Int32) throws -> DisplayLayout {
        try DisplayLayout(
            main: mainIdentity,
            origins: [
                mainIdentity: DisplayOrigin(x: 0, y: 0),
                outerIdentity: DisplayOrigin(x: otherX, y: 0)
            ]
        )
    }

    private func recordURL(in directory: URL) -> URL {
        directory.appendingPathComponent("recovery-record.json")
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(
            fileURLWithPath: "/private/tmp/extilume-recovery-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        guard mkdir(directory.path, mode_t(0o700)) == 0 else {
            throw RecoveryStoreError.ioFailure
        }
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
