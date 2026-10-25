import Foundation
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

@MainActor
final class DisplayModeCoordinatorTests: XCTestCase {
    private final class Preferences: DisplayModePreferenceStoring {
        var selectedMode: DisplayApplicationMode?
        var internalControlLocked = false
        func select(_ mode: DisplayApplicationMode) throws { selectedMode = mode }
        func lockInternalControl() throws { internalControlLocked = true }
    }

    private final class Session: PrimaryApplicationControlling {
        var handler: (@Sendable (PrimarySessionStatus) -> Void)?
        var quitCompletion: (@Sendable (Bool) -> Void)?
        var starts = 0
        var recoveries = 0
        var confirmations = 0
        var retries = 0
        var recoveryOnly = false
        func startApplication(registerEvents: Bool, recoveryOnly: Bool,
                              onStatus: @escaping @Sendable (PrimarySessionStatus) -> Void) {
            starts += 1
            self.recoveryOnly = recoveryOnly
            handler = onStatus
        }
        func retryApplication() { retries += 1 }
        func recoverApplication() { recoveries += 1 }
        func confirmCurrentConfiguration() { confirmations += 1 }
        func quitApplication(completion: @escaping @Sendable (Bool) -> Void) { quitCompletion = completion }
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func drain() async {
        for _ in 0..<4 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(10))
    }

    func testFirstLaunchAndSavedOnlyExternalWaitForExplicitAction() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = Preferences()
        var calls = 0
        var coordinator: DisplayModeCoordinator? = try DisplayModeCoordinator(directory: root, preferences: preferences) { _, _, _ in
            calls += 1
            return Session()
        }
        coordinator?.startApplication(registerEvents: false, recoveryOnly: false) { _ in }
        XCTAssertNil(coordinator?.selectedMode)
        XCTAssertEqual(calls, 0)
        coordinator = nil
        preferences.selectedMode = .externalOnly
        let restored = try DisplayModeCoordinator(directory: root, preferences: preferences) { _, _, _ in
            calls += 1
            return Session()
        }
        restored.startApplication(registerEvents: false, recoveryOnly: false) { _ in }
        XCTAssertEqual(restored.selectedMode, .externalOnly)
        XCTAssertTrue(restored.requiresExplicitActivation)
        XCTAssertEqual(calls, 0)
        restored.selectMode(.externalOnly)
        XCTAssertFalse(restored.requiresExplicitActivation)
        XCTAssertEqual(calls, 1)
    }

    func testSwitchWaitsForRecoveryAndIgnoresLateOldStatus() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = Preferences()
        let primary = Session()
        let internalSession = Session()
        var modes: [DisplayApplicationMode] = []
        let coordinator = try DisplayModeCoordinator(directory: root, preferences: preferences) { mode, _, store in
            modes.append(mode)
            XCTAssertEqual(store != nil, mode == .externalPrimary)
            return mode == .externalPrimary ? primary : internalSession
        }
        coordinator.startApplication(registerEvents: false, recoveryOnly: false) { _ in }
        coordinator.selectMode(.externalPrimary)
        primary.handler?(.applied)
        await drain()
        coordinator.selectMode(.externalOnly)
        coordinator.selectMode(.externalPrimary)
        XCTAssertEqual(modes, [.externalPrimary])
        primary.handler?(.applied)
        primary.quitCompletion?(true)
        await drain()
        XCTAssertEqual(modes, [.externalPrimary, .externalOnly])
        XCTAssertEqual(internalSession.starts, 1)
        primary.handler?(.quitFailed)
        internalSession.handler?(.applied)
        await drain()
        XCTAssertFalse(preferences.internalControlLocked)
        coordinator.restoreForConfiguration()
        coordinator.restoreForConfiguration()
        XCTAssertEqual(internalSession.recoveries, 1)
        internalSession.handler?(.manualConfiguration)
        await drain()
        coordinator.confirmCurrentConfiguration()
        XCTAssertEqual(internalSession.confirmations, 1)
    }

    func testFailedRecoveryRetainsOwnerAndPersistentDisableLatch() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = Preferences()
        let internalSession = Session()
        var calls = 0
        let coordinator = try DisplayModeCoordinator(directory: root, preferences: preferences) { _, _, _ in
            calls += 1
            return internalSession
        }
        coordinator.startApplication(registerEvents: false, recoveryOnly: false) { _ in }
        coordinator.selectMode(.externalOnly)
        internalSession.handler?(.applied)
        await drain()
        coordinator.selectMode(.externalPrimary)
        internalSession.quitCompletion?(false)
        await drain()
        XCTAssertTrue(preferences.internalControlLocked)
        XCTAssertEqual(calls, 1)
        coordinator.selectMode(.externalOnly)
        XCTAssertEqual(calls, 1)
        coordinator.recoverApplication()
        XCTAssertEqual(internalSession.recoveries, 1)
        internalSession.handler?(.applicationFailedRestored)
        await drain()
        coordinator.selectMode(.externalOnly)
        XCTAssertEqual(calls, 1)
    }

    func testRootLeaseBlocksSecondOwnerEvenWithSeparateModeState() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try DisplayModeCoordinator(directory: root, preferences: Preferences()) { _, _, _ in Session() }
        try withExtendedLifetime(owner) {
            XCTAssertThrowsError(try DisplayModeCoordinator(directory: root, preferences: Preferences()) { _, _, _ in Session() })
            XCTAssertThrowsError(try PrimaryController(directory: root))
        }
    }

    func testBlockedIntentCannotTurnPrimaryOwnerStatusIntoOnlyExternalSuccessOrConfirmation() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = Preferences()
        preferences.internalControlLocked = true
        let primary = Session()
        let coordinator = try DisplayModeCoordinator(directory: root, preferences: preferences) { _, _, _ in primary }
        let statuses = StatusValues()
        coordinator.startApplication(registerEvents: false, recoveryOnly: false) { statuses.append($0) }
        coordinator.selectMode(.externalPrimary)
        primary.handler?(.applied)
        await drain()
        coordinator.selectMode(.externalOnly)
        primary.handler?(.manualConfiguration)
        await drain()
        guard case .unsupported = statuses.last else { return XCTFail("Old owner must not expose only-external actions") }
        coordinator.confirmCurrentConfiguration()
        XCTAssertEqual(primary.confirmations, 0)
        primary.handler?(.applied)
        await drain()
        guard case .unsupported = statuses.last else { return XCTFail("Preference is not physical effect") }
        coordinator.selectMode(.externalPrimary)
        XCTAssertEqual(statuses.last, .applied)
    }

    func testRecoveredRetiringPrimaryIsReplacedBeforeReapplication() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = Session()
        let fresh = Session()
        var creations = 0
        let coordinator = try DisplayModeCoordinator(directory: root, preferences: Preferences()) { _, _, _ in
            creations += 1
            return creations == 1 ? old : fresh
        }
        coordinator.startApplication(registerEvents: false, recoveryOnly: false) { _ in }
        coordinator.selectMode(.externalPrimary)
        old.handler?(.applied)
        await drain()
        coordinator.selectMode(.externalOnly)
        old.quitCompletion?(false)
        await drain()
        coordinator.recoverApplication()
        old.handler?(.applicationFailedRestored)
        await drain()
        coordinator.selectMode(.externalPrimary)
        XCTAssertEqual(old.retries, 0)
        old.quitCompletion?(true)
        await drain()
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(fresh.starts, 1)
    }

    func testCleanupFailureKeepsRecoveryOwnerAndRejectsQuitUntilRetried() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try saveRestoredRecord(root)
        let primary = Session()
        let coordinator = try DisplayModeCoordinator(directory: root, preferences: Preferences()) { _, _, _ in primary }
        coordinator.startApplication(registerEvents: false, recoveryOnly: false) { _ in }
        XCTAssertTrue(primary.recoveryOnly)
        primary.handler?(.applicationFailedRestored)
        await drain()
        let record = root.appendingPathComponent("recovery-record.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: record.path)
        coordinator.selectMode(.externalOnly)
        primary.quitCompletion?(true)
        await drain()
        let rejected = expectation(description: "Unsettled cleanup cannot report successful quit")
        coordinator.quitApplication { success in XCTAssertFalse(success); rejected.fulfill() }
        await fulfillment(of: [rejected], timeout: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: record.path)
        coordinator.recoverApplication()
        primary.quitCompletion?(true)
        await drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    private func saveRestoredRecord(_ directory: URL) throws {
        let builtIn = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let external = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let layout = try DisplayLayout(main: builtIn, origins: [builtIn: DisplayOrigin(x: 0, y: 0),
                                                             external: DisplayOrigin(x: 100, y: 0)])
        var record = try RecoveryRecord(baseline: layout, target: layout)
        try record.markApplying()
        try record.confirmApplied(layout)
        record.beginRestoration()
        try record.confirmRestored(actual: layout)
        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        try store.save(record)
    }

    private final class StatusValues: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [PrimarySessionStatus] = []
        func append(_ status: PrimarySessionStatus) { lock.withLock { values.append(status) } }
        var last: PrimarySessionStatus? { lock.withLock { values.last } }
    }

    func testModePreferenceCorruptionAndFailureLockSurviveRecreation() throws {
        let name = "ExtilumePreferenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = DisplayModePreferences(defaults: defaults)
        XCTAssertNil(preferences.selectedMode)
        try preferences.select(.externalOnly)
        XCTAssertEqual(DisplayModePreferences(defaults: defaults).selectedMode, .externalOnly)
        try preferences.lockInternalControl()
        try preferences.select(.externalPrimary)
        XCTAssertTrue(DisplayModePreferences(defaults: defaults).internalControlLocked)
        defaults.set("unsupported", forKey: "explicitDisplayMode.v1")
        XCTAssertNil(preferences.selectedMode)
        defaults.set("malformed", forKey: "internalControlFailure.v1")
        XCTAssertTrue(preferences.internalControlLocked)
    }
}
