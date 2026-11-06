import Darwin
import Foundation
import XCTest
@testable import ExtilumeCore

final class LayoutResponsibilityCloseoutTests: XCTestCase {
    private let main = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let other = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
    private enum Failure: Error { case injected }

    func testCloseoutPreservesIdentityAndBacksUpExactBytes() throws {
        try withStore { store, _, original in
            let before = try XCTUnwrap(store.load())
            var backup: Data?
            var verifies = 0
            let target = try layout(200)
            let result = try store.closeLayoutResponsibility(expectedOriginal: original, target: target, backup: { backup = $0 }, verify: { verifies += 1 }, beforeSave: {})
            XCTAssertEqual(backup, original)
            XCTAssertEqual(verifies, 3)
            XCTAssertEqual(result, try store.load())
            XCTAssertEqual(result.phase, .restored)
            XCTAssertEqual(result.baseline, target)
            XCTAssertEqual(result.session, before.session)
            XCTAssertEqual(result.generation, before.generation)
            XCTAssertEqual(result.version, before.version)
            XCTAssertEqual(result.applied, before.applied)
        }
    }

    func testLegacyVersionOneIsClosedWithoutVersionMigration() throws {
        try withStore { store, directory, original in
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            object["version"] = 1
            let legacy = try JSONSerialization.data(withJSONObject: object)
            try legacy.write(to: directory.appendingPathComponent("recovery-record.json"))
            var backedUp: Data?
            let closed = try store.closeLayoutResponsibility(expectedOriginal: legacy, target: layout(200),
                backup: { backedUp = $0 }, verify: {}, beforeSave: {})
            XCTAssertEqual(backedUp, legacy)
            XCTAssertEqual(closed.version, 1)
            XCTAssertEqual(try store.load(), closed)
        }
    }

    func testRejectsAppliedMissingAndPreparedWithoutWriting() throws {
        try withStore { store, _, original in
            let before = try XCTUnwrap(store.load())
            let missing = try DisplayLayout(main: main, origins: [main: DisplayOrigin(x: 0, y: 0)])
            for target in [before.applied, missing] {
                XCTAssertThrowsError(try close(store, original, target))
                XCTAssertEqual(try store.loadWithOriginalBytes()?.bytes, original)
            }
        }
        try withStore(owned: false) { store, _, original in
            XCTAssertThrowsError(try close(store, original, layout(200)))
            XCTAssertEqual(try store.loadWithOriginalBytes()?.bytes, original)
        }
    }

    func testRejectsUnresolvedAndDisplayResponsibilities() throws {
        let internalDisplay = InternalDisplayResponsibility(identity: main, baseline: true, applied: true)
        let externalDisplay = ExternalDisplayResponsibility(
            identity: ExternalDisplayIdentity(uuid: other, registryPath: "fixture", edidUUID: "fixture", bootSession: UUID(), registryEntryID: 1),
            numericIDHint: 2, baseline: true, applied: true
        )
        for kind in 0...2 {
            try withStore(internalDisplay: kind == 1 ? internalDisplay : nil, externalDisplay: kind == 2 ? externalDisplay : nil, unresolved: kind == 0) { store, _, original in
                XCTAssertThrowsError(try close(store, original, layout(200)))
                XCTAssertEqual(try store.loadWithOriginalBytes()?.bytes, original)
            }
        }
    }

    func testRequiresOwnershipAndOriginalBytes() throws {
        try withStore { owner, directory, original in
            let otherStore = try RecoveryStore(directory: directory)
            XCTAssertThrowsError(try otherStore.acquireExclusiveOwnership())
            XCTAssertThrowsError(try close(otherStore, original, layout(200)))
            XCTAssertThrowsError(try close(owner, original + Data(" ".utf8), layout(200)))
            XCTAssertEqual(try owner.loadWithOriginalBytes()?.bytes, original)
        }
    }

    func testChangedBytesAfterBackupPreventSave() throws {
        try withStore { store, directory, original in
            let changed = original + Data(" ".utf8)
            XCTAssertThrowsError(try store.closeLayoutResponsibility(expectedOriginal: original, target: layout(200), backup: { _ in }, verify: {}, beforeSave: {
                try changed.write(to: directory.appendingPathComponent("recovery-record.json"))
            }))
            XCTAssertEqual(try store.loadWithOriginalBytes()?.bytes, changed)
            XCTAssertEqual(try store.load()?.phase, .owned)
        }
    }

    func testInjectedFailuresLeaveExpectedRecord() throws {
        for failureAt in 0...3 {
            try withStore { store, _, original in
                var verifies = 0
                XCTAssertThrowsError(try store.closeLayoutResponsibility(expectedOriginal: original, target: layout(200), backup: { _ in
                    if failureAt == 0 { throw Failure.injected }
                }, verify: {
                    verifies += 1
                    if (failureAt == 1 && verifies == 2) || (failureAt == 3 && verifies == 3) { throw Failure.injected }
                }, beforeSave: {
                    if failureAt == 2 { throw Failure.injected }
                }))
                if failureAt == 3 {
                    XCTAssertEqual(try store.load()?.phase, .restored)
                    XCTAssertNotEqual(try store.loadWithOriginalBytes()?.bytes, original)
                } else {
                    XCTAssertEqual(try store.loadWithOriginalBytes()?.bytes, original)
                }
            }
        }
    }

    func testInsecureDirectoryBeforeSavePreservesOriginalRecord() throws {
        try withStore { store, directory, original in
            defer { _ = chmod(directory.path, 0o700) }
            XCTAssertThrowsError(try store.closeLayoutResponsibility(expectedOriginal: original, target: layout(200), backup: { _ in }, verify: {}, beforeSave: {
                guard chmod(directory.path, 0o755) == 0 else { throw Failure.injected }
            }))
            XCTAssertEqual(chmod(directory.path, 0o700), 0)
            XCTAssertEqual(try store.loadWithOriginalBytes()?.bytes, original)
        }
    }

    func testFinalAdmissionFailureCannotReplaceRecord() throws {
        try withStore { store, _, original in
            XCTAssertThrowsError(try store.closeLayoutResponsibility(expectedOriginal: original, target: layout(200),
                backup: { _ in }, verify: {}, beforeSave: {}, checkBeforeCommit: { throw Failure.injected }))
            XCTAssertEqual(try store.loadWithOriginalBytes()?.bytes, original)
        }
    }

    func testReplacementSyncFailurePreservesUncertainCloseoutButOrdinarySaveStillRollsBack() throws {
        for closeout in [true, false] {
            let directory = URL(fileURLWithPath: "/private/tmp/extilume-closeout-sync-\(UUID().uuidString)")
            guard mkdir(directory.path, 0o700) == 0 else { throw Failure.injected }
            defer { try? FileManager.default.removeItem(at: directory) }
            let applied = try layout(-100)
            var original = try RecoveryRecord(baseline: layout(100), target: applied)
            try original.confirmApplied(applied)
            do {
                let setup = try RecoveryStore(directory: directory)
                try setup.acquireExclusiveOwnership()
                try setup.save(original)
            }
            var synchronizations = 0
            let store = try RecoveryStore(directory: directory, synchronize: { fd in
                synchronizations += 1
                if synchronizations == 3 { throw Failure.injected }
                guard fsync(fd) == 0 else { throw Failure.injected }
            })
            try store.acquireExclusiveOwnership()
            let bytes = try XCTUnwrap(store.loadWithOriginalBytes()?.bytes)
            if closeout {
                XCTAssertThrowsError(try close(store, bytes, layout(200)))
                XCTAssertEqual(try store.load()?.phase, .restored)
                let retained = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                    .filter { $0.hasPrefix(".recovery-backup-") }
                XCTAssertEqual(retained.count, 1)
                XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(retained[0])), bytes)
            } else {
                XCTAssertThrowsError(try store.save(original.confirmingLayoutCloseout(actual: layout(200))))
                XCTAssertEqual(try store.loadWithOriginalBytes()?.bytes, bytes)
            }
        }
    }

    private func close(_ store: RecoveryStore, _ bytes: Data, _ target: DisplayLayout) throws -> RecoveryRecord {
        try store.closeLayoutResponsibility(expectedOriginal: bytes, target: target, backup: { _ in }, verify: {}, beforeSave: {})
    }

    private func layout(_ x: Int32) throws -> DisplayLayout {
        try DisplayLayout(main: main, origins: [main: DisplayOrigin(x: 0, y: 0), other: DisplayOrigin(x: x, y: 0)])
    }

    private func withStore(owned: Bool = true, internalDisplay: InternalDisplayResponsibility? = nil, externalDisplay: ExternalDisplayResponsibility? = nil, unresolved: Bool = false, _ body: (RecoveryStore, URL, Data) throws -> Void) throws {
        let directory = URL(fileURLWithPath: "/private/tmp/extilume-closeout-tests-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(directory.path, 0o700) == 0 else { throw RecoveryStoreError.ioFailure }
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        let applied = try layout(-100)
        var record = try RecoveryRecord(baseline: layout(100), target: applied, internalDisplay: internalDisplay, externalDisplay: externalDisplay)
        if owned { try record.confirmApplied(applied, internalEnabled: internalDisplay?.applied, externalEnabled: externalDisplay?.applied) }
        if unresolved { XCTAssertThrowsError(try record.observe(layout(200), source: .unknown)) }
        try store.save(record)
        let original = try XCTUnwrap(store.loadWithOriginalBytes()?.bytes)
        try body(store, directory, original)
    }
}
