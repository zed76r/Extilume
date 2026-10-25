import CoreGraphics
import Foundation
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

final class PrimaryStartupTests: XCTestCase {
    private let internalID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let externalID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!

    func testSecondControllerCannotTakeDirectoryOwnershipOrReplaceRecord() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try seedOwnedRecord(in: directory)
        let originalData = try recordData(in: directory)
        let fixture = ControllerFixture(snapshot: try builtInOnlySnapshot())
        let first = try makeController(directory: directory, fixture: fixture)
        try withExtendedLifetime(first) {
            XCTAssertThrowsError(try makeController(directory: directory, fixture: fixture)) { error in
                XCTAssertEqual(error as? RecoveryStoreError, .ownershipUnavailable)
            }
            XCTAssertEqual(try readRecord(in: directory), original)
            XCTAssertEqual(try recordData(in: directory), originalData)
            XCTAssertTrue(fixture.writes.isEmpty)
        }
    }

    func testInsecureDirectoryIsRejectedWithoutPermissionRepair() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try seedOwnedRecord(in: directory)
        let originalData = try recordData(in: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let fixture = ControllerFixture(snapshot: try builtInOnlySnapshot())

        XCTAssertThrowsError(try makeController(directory: directory, fixture: fixture)) { error in
            XCTAssertEqual(error as? RecoveryStoreError, .insecureDirectory)
        }
        XCTAssertEqual(try permissions(at: directory.path), 0o755)
        XCTAssertEqual(try recordData(in: directory), originalData)
        XCTAssertTrue(fixture.writes.isEmpty)
    }

    func testSymlinkDirectoriesAndRecordsAreRejectedWithoutFollowingThem() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let realDirectory = try makeDirectory(in: root, name: "real")
        _ = try seedOwnedRecord(in: realDirectory)
        let originalData = try recordData(in: realDirectory)
        let directoryLink = root.appendingPathComponent("directory-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: realDirectory)
        let fixture = ControllerFixture(snapshot: try builtInOnlySnapshot())
        XCTAssertThrowsError(try makeController(directory: directoryLink, fixture: fixture)) { error in
            XCTAssertEqual(error as? RecoveryStoreError, .insecureDirectory)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: directoryLink.path), realDirectory.path)
        XCTAssertEqual(try recordData(in: realDirectory), originalData)
        XCTAssertTrue(fixture.writes.isEmpty)

        let recordDirectory = try makeDirectory(in: root, name: "record-link")
        let sentinel = recordDirectory.appendingPathComponent("sentinel")
        let sentinelData = Data("keep sentinel".utf8)
        try sentinelData.write(to: sentinel)
        let recordLink = recordDirectory.appendingPathComponent("recovery-record.json")
        try FileManager.default.createSymbolicLink(atPath: recordLink.path, withDestinationPath: sentinel.path)
        let recordFixture = ControllerFixture(snapshot: try builtInOnlySnapshot())
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: recordDirectory, fixture: recordFixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }

        XCTAssertTrue(statuses.wait(for: .recoveryIncomplete))
        XCTAssertTrue(recordFixture.writes.isEmpty)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: recordLink.path), sentinel.path)
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelData)
        controller = nil
    }

    func testRecoveryOnlyClearsCompletedResponsibilityButWaitsForExplicitRetry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let restored = try seedRestoredRecord(in: directory)
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(baseline), afterApplication: try makeSnapshot(target))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false, recoveryOnly: true) { statuses.append($0) }

        XCTAssertTrue(statuses.wait(for: .applicationFailedRestored))
        XCTAssertNil(try readRecord(in: directory))
        XCTAssertTrue(fixture.writes.isEmpty)
        XCTAssertEqual(try fixture.snapshot().layout(), baseline)

        controller?.retryApplication()
        XCTAssertTrue(statuses.wait(for: .applied))
        let applied = try XCTUnwrap(readRecord(in: directory))
        XCTAssertNotEqual(applied.session, restored.session)
        XCTAssertEqual(applied.phase, .owned)
        XCTAssertEqual(applied.baseline, baseline)
        XCTAssertEqual(applied.applied, target)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true])
        XCTAssertEqual(try fixture.snapshot().layout(), target)
        controller = nil
    }

    func testMissingExternalDisplayKeepsPriorRecoveryResponsibility() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try seedOwnedRecord(in: directory)
        let fixture = ControllerFixture(snapshot: try builtInOnlySnapshot())
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }

        XCTAssertTrue(statuses.wait(for: .recoveryIncomplete))
        var pending = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(pending.session, original.session)
        XCTAssertEqual(pending.phase, .restoring)
        XCTAssertTrue(pending.layoutPending)
        XCTAssertFalse(pending.canClear)
        XCTAssertEqual(fixture.writes.map(\.origins), [[80: DisplayOrigin(x: 0, y: 0)]])
        XCTAssertEqual(fixture.writes.map(\.appOnly), [false])

        controller?.recoverApplication()
        XCTAssertTrue(statuses.wait(for: .recoveryIncomplete, count: 2))
        pending = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(pending.session, original.session)
        XCTAssertEqual(pending.phase, .restoring)
        XCTAssertFalse(pending.canClear)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [false, false])
        controller = nil
    }

    func testUnconfirmedPriorSourceCannotBeClearedByStartupOrRecoveryRetry() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pending = try seedUnconfirmedRecord(in: directory)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(try layout(mainExternal: true)))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }

        XCTAssertTrue(statuses.wait(for: .recoveryIncomplete))
        controller?.recoverApplication()
        XCTAssertTrue(statuses.wait(for: .recoveryIncomplete, count: 2))
        let retained = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(retained, pending)
        XCTAssertTrue(retained.sourceUnresolved)
        XCTAssertTrue(fixture.writes.isEmpty)
        controller = nil
    }

    func testCompletedPriorLayoutChangeRequiresConfirmationThenCanApplyAndRestoreNewBaseline() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try seedRestoredRecord(in: directory)
        let changed = try layout(externalX: -2560)
        let target = try layoutByMakingMain(changed, target: externalID)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(changed),
                                        afterApplication: try makeSnapshot(target),
                                        afterRestoration: try makeSnapshot(changed))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }

        XCTAssertTrue(statuses.wait(for: .unconfirmed))
        XCTAssertEqual(try readRecord(in: directory), original)
        XCTAssertTrue(fixture.writes.isEmpty)
        controller?.recoverApplication()
        XCTAssertTrue(statuses.wait(for: .unconfirmed, count: 2))
        XCTAssertEqual(try readRecord(in: directory), original)
        XCTAssertTrue(fixture.writes.isEmpty)

        controller?.displayChanged(.desktopShapeChangedFlag)
        controller?.confirmCurrentConfiguration()
        XCTAssertTrue(statuses.wait(for: .manualConfiguration))
        let confirmed = try XCTUnwrap(readRecord(in: directory))
        XCTAssertNotEqual(confirmed.session, original.session)
        XCTAssertEqual(confirmed.phase, .owned)
        XCTAssertEqual(confirmed.baseline, changed)
        XCTAssertEqual(confirmed.applied, changed)
        XCTAssertFalse(confirmed.sourceUnresolved)
        XCTAssertFalse(confirmed.layoutPending)
        XCTAssertTrue(fixture.writes.isEmpty)

        controller?.retryApplication()
        XCTAssertTrue(statuses.wait(for: .applied))
        XCTAssertEqual(try readRecord(in: directory)?.baseline, changed)
        XCTAssertEqual(try readRecord(in: directory)?.applied, target)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true])

        let quit = expectation(description: "restore explicitly selected layout")
        controller?.quitApplication { success in
            XCTAssertTrue(success)
            quit.fulfill()
        }
        wait(for: [quit], timeout: 4)
        XCTAssertEqual(try fixture.snapshot().layout(), changed)
        XCTAssertEqual(try readRecord(in: directory)?.phase, .restored)
        XCTAssertEqual(try readRecord(in: directory)?.baseline, changed)
        XCTAssertEqual(fixture.writes.map(\.appOnly), [true, false])
        controller = nil
    }

    func testChangeAfterRestartConfirmationCannotBeAdoptedByExplicitApplication() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try seedRestoredRecord(in: directory)
        let changed = try layout(externalX: -2560)
        let fixture = ControllerFixture(snapshot: try makeSnapshot(changed))
        let statuses = StatusRecorder()
        var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
        controller?.startApplication(registerEvents: false) { statuses.append($0) }
        XCTAssertTrue(statuses.wait(for: .unconfirmed))
        controller?.confirmCurrentConfiguration()
        XCTAssertTrue(statuses.wait(for: .manualConfiguration))

        fixture.setSnapshot(try makeSnapshot(try layout(externalX: -3000)))
        controller?.retryApplication()
        XCTAssertTrue(statuses.wait(for: .unconfirmed, count: 2))
        let retained = try XCTUnwrap(readRecord(in: directory))
        XCTAssertEqual(retained.baseline, changed)
        XCTAssertTrue(retained.sourceUnresolved)
        XCTAssertTrue(fixture.writes.isEmpty)
        controller = nil
    }

    func testRestartConfirmationRejectsOldAppliedLayoutAndMissingDisplays() throws {
        for snapshot in [try makeSnapshot(try layout(mainExternal: true)), try builtInOnlySnapshot()] {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let original = try seedRestoredRecord(in: directory)
            let fixture = ControllerFixture(snapshot: snapshot)
            let statuses = StatusRecorder()
            var controller: PrimaryController? = try makeController(directory: directory, fixture: fixture)
            controller?.startApplication(registerEvents: false) { statuses.append($0) }
            XCTAssertTrue(statuses.wait(for: .unconfirmed))
            controller?.confirmCurrentConfiguration()
            XCTAssertTrue(statuses.wait(for: .confirmationFailed))
            XCTAssertEqual(try readRecord(in: directory), original)
            XCTAssertTrue(fixture.writes.isEmpty)
            controller = nil
        }
    }

    private struct WriteCall: Equatable {
        let origins: [UInt32: DisplayOrigin]
        let appOnly: Bool
    }

    private final class ControllerFixture: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Snapshot
        private var recordedWrites: [WriteCall] = []
        private let afterApplication: Snapshot?
        private let afterRestoration: Snapshot?

        init(snapshot: Snapshot, afterApplication: Snapshot? = nil, afterRestoration: Snapshot? = nil) {
            current = snapshot
            self.afterApplication = afterApplication
            self.afterRestoration = afterRestoration
        }

        var writes: [WriteCall] { lock.withLock { recordedWrites } }

        func snapshot() -> Snapshot { lock.withLock { current } }

        func setSnapshot(_ snapshot: Snapshot) { lock.withLock { current = snapshot } }

        func write(_ origins: [UInt32: DisplayOrigin], option: CGConfigureOption) {
            lock.withLock {
                recordedWrites.append(WriteCall(origins: origins, appOnly: option == .forAppOnly))
                if option == .forAppOnly, let afterApplication { current = afterApplication }
                if option == .forSession, let afterRestoration { current = afterRestoration }
            }
        }
    }

    private final class StatusRecorder: @unchecked Sendable {
        private let condition = NSCondition()
        private var values: [PrimarySessionStatus] = []

        func append(_ status: PrimarySessionStatus) {
            condition.lock()
            values.append(status)
            condition.broadcast()
            condition.unlock()
        }

        func wait(for status: PrimarySessionStatus, count: Int = 1, timeout: TimeInterval = 4) -> Bool {
            let deadline = Date(timeIntervalSinceNow: timeout)
            condition.lock()
            defer { condition.unlock() }
            while values.filter({ $0 == status }).count < count {
                if !condition.wait(until: deadline) { return false }
            }
            return true
        }
    }

    private func makeController(directory: URL, fixture: ControllerFixture) throws -> PrimaryController {
        try PrimaryController(
            directory: directory,
            snapshotReader: { fixture.snapshot() },
            originWriter: { origins, option in fixture.write(origins, option: option) },
            lidReader: { "开盖" }
        )
    }

    private func layout(mainExternal: Bool = false, internalX: Int32? = nil, externalX: Int32? = nil) throws -> DisplayLayout {
        let builtInX = internalX ?? (mainExternal ? -1728 : 0)
        let externalX: Int32 = externalX ?? (mainExternal ? 0 : 1728)
        return try DisplayLayout(
            main: mainExternal ? externalID : internalID,
            origins: [
                internalID: DisplayOrigin(x: builtInX, y: 0),
                externalID: DisplayOrigin(x: externalX, y: 0)
            ]
        )
    }

    private func makeSnapshot(_ layout: DisplayLayout) throws -> Snapshot {
        Snapshot(displays: [
            makeDisplay(id: 80, identity: .builtIn, uuid: internalID, layout: layout),
            makeDisplay(id: 40, identity: .physical, uuid: externalID, layout: layout)
        ])
    }

    private func builtInOnlySnapshot() throws -> Snapshot {
        let baseline = try layout()
        return Snapshot(displays: [makeDisplay(id: 80, identity: .builtIn, uuid: internalID, layout: baseline)])
    }

    private func makeDisplay(id: UInt32, identity: DisplayIdentity, uuid: UUID, layout: DisplayLayout) -> DisplayState {
        let origin = layout.origins[uuid] ?? DisplayOrigin(x: 0, y: 0)
        return DisplayState(
            id: id,
            identity: identity,
            identityUUID: uuid,
            isOnline: true,
            isActive: true,
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

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ExtilumePrimaryStartup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func makeDirectory(in parent: URL, name: String) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func seedOwnedRecord(in directory: URL) throws -> RecoveryRecord {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        return try store.apply(RecoveryRecord(baseline: baseline, target: target)) { (target, nil) }
    }

    private func seedRestoredRecord(in directory: URL) throws -> RecoveryRecord {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        var record = try store.apply(RecoveryRecord(baseline: baseline, target: target)) { (target, nil) }
        record.beginRestoration()
        try record.confirmRestored(actual: baseline)
        try store.save(record)
        return record
    }

    private func seedUnconfirmedRecord(in directory: URL) throws -> RecoveryRecord {
        let baseline = try layout()
        let target = try layout(mainExternal: true)
        let unknown = try layout(mainExternal: true, internalX: -1920)
        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        var record = try store.apply(RecoveryRecord(baseline: baseline, target: target)) { (target, nil) }
        XCTAssertThrowsError(try record.observe(unknown, source: .unknown))
        XCTAssertTrue(record.sourceUnresolved)
        try store.save(record)
        return record
    }

    private func readRecord(in directory: URL) throws -> RecoveryRecord? {
        try RecoveryStore(directory: directory).load()
    }

    private func recordData(in directory: URL) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("recovery-record.json"))
    }

    private func permissions(at path: String) throws -> Int? {
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        return mode.map { $0.intValue & 0o7777 }
    }
}
