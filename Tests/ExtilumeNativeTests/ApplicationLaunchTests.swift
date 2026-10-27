import Darwin
import Foundation
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

final class ApplicationLaunchTests: XCTestCase {
    func testExplicitDirectorySkipsSupportLookupAndCreation() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let customPath = root.appendingPathComponent("missing-state", isDirectory: true)
        var supportCalls = 0

        let result = try applicationLaunchOptions(arguments: ["--state-directory", customPath.path]) {
            supportCalls += 1
            return root
        }

        XCTAssertEqual(result.stateDirectory, customPath)
        XCTAssertFalse(result.verifiesExternalHandoff)
        XCTAssertEqual(supportCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: customPath.path))
    }

    func testExternalHandoffArgumentsRequireExactOptInAndDoNotCreateDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let customPath = root.appendingPathComponent("missing-state", isDirectory: true)
        var supportCalls = 0

        let result = try applicationLaunchOptions(arguments: [
            "--verify-external-handoff", "--allow-display-write", "--state-directory", customPath.path
        ]) {
            supportCalls += 1
            return root
        }

        XCTAssertEqual(result.stateDirectory, customPath)
        XCTAssertTrue(result.verifiesExternalHandoff)
        XCTAssertEqual(supportCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: customPath.path))
    }

    func testInvalidArgumentsFailBeforeSupportLookup() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidArguments = [
            ["--unknown"],
            ["--state-directory"],
            ["--state-directory", ""],
            ["--state-directory", "--other"],
            ["--state-directory", "/one", "extra"],
            ["--state-directory", "/one", "--state-directory", "/two"],
            ["--verify-external-handoff"],
            ["--verify-external-handoff", "--state-directory", "/one"],
            ["--allow-display-write", "--state-directory", "/one"],
            ["--verify-external-handoff", "--allow-display-write", "--state-directory"],
            ["--verify-external-handoff", "--allow-display-write", "--state-directory", ""],
            ["--verify-external-handoff", "--allow-display-write", "--state-directory", "--other"],
            ["--state-directory", "/one", "--allow-display-write", "--verify-external-handoff"],
            ["--verify-external-handoff", "--allow-display-write", "--state-directory", "/one", "extra"]
        ]
        var supportCalls = 0

        for arguments in invalidArguments {
            XCTAssertThrowsError(try applicationLaunchOptions(arguments: arguments) {
                supportCalls += 1
                return root
            }) { error in
                XCTAssertEqual(error as? ApplicationLaunchError, .invalidArguments)
            }
        }

        XCTAssertEqual(supportCalls, 0)
    }

    func testDefaultFirstRunCreatesPrivateStateDirectory() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }

        let result = try applicationLaunchOptions(arguments: []) { support }

        XCTAssertEqual(result.stateDirectory, support.appendingPathComponent("Extilume", isDirectory: true))
        XCTAssertFalse(result.verifiesExternalHandoff)
        XCTAssertEqual(try permissions(at: result.stateDirectory), 0o700)
    }

    func testExistingDirectoryPermissionsAndContentsAreUnchanged() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let stateDirectory = try makeDirectory(in: support, name: "Extilume", mode: 0o755)
        let sentinel = stateDirectory.appendingPathComponent("keep.txt")
        let contents = Data("keep existing state".utf8)
        try contents.write(to: sentinel)

        let result = try applicationLaunchOptions(arguments: []) { support }

        XCTAssertEqual(result.stateDirectory, stateDirectory)
        XCTAssertEqual(try permissions(at: stateDirectory), 0o755)
        XCTAssertEqual(try Data(contentsOf: sentinel), contents)
    }

    func testExistingDirectorySymlinkIsPreserved() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let target = try makeDirectory(in: support, name: "target", mode: 0o755)
        let sentinel = target.appendingPathComponent("keep.txt")
        let contents = Data("keep target".utf8)
        try contents.write(to: sentinel)
        let stateLink = support.appendingPathComponent("Extilume", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: stateLink, withDestinationURL: target)

        let result = try applicationLaunchOptions(arguments: []) { support }

        XCTAssertEqual(result.stateDirectory, stateLink)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: stateLink.path), target.path)
        XCTAssertEqual(try permissions(at: target), 0o755)
        XCTAssertEqual(try Data(contentsOf: sentinel), contents)
    }

    func testSupportDirectoryFailurePropagates() throws {
        enum ExpectedFailure: Error { case lookup }

        XCTAssertThrowsError(try applicationLaunchOptions(arguments: []) {
            throw ExpectedFailure.lookup
        }) { error in
            XCTAssertTrue(error is ExpectedFailure)
        }
    }

    func testMissingSupportParentReturnsStaticCreationError() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingSupport = root.appendingPathComponent("missing-support", isDirectory: true)

        XCTAssertThrowsError(try applicationLaunchOptions(arguments: []) { missingSupport }) { error in
            XCTAssertEqual(error as? RecoveryStoreError, .ioFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingSupport.appendingPathComponent("Extilume").path))
    }

    @MainActor
    func testApplicationLeaseBlocksSeparateProfilesAndReleasesAfterLegacyConflict() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lock = root.appendingPathComponent("owner", isDirectory: true)
        var first: RecoveryStore? = try acquireApplicationControlLease(directory: lock, hasOtherApplication: { false })
        XCTAssertThrowsError(try acquireApplicationControlLease(directory: lock, hasOtherApplication: { false }))
        XCTAssertNotNil(first)
        first = nil
        XCTAssertThrowsError(try acquireApplicationControlLease(directory: lock, hasOtherApplication: { true })) { error in
            XCTAssertEqual(error as? ApplicationLaunchError, .anotherApplicationRunning)
        }
        XCTAssertNoThrow(try acquireApplicationControlLease(directory: lock, hasOtherApplication: { false }))
    }

    func testExternalHandoffDirectoryIsNeverCreatedOrRepaired() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing", isDirectory: true)
        let missingOptions = try applicationLaunchOptions(arguments: [
            "--verify-external-handoff", "--allow-display-write", "--state-directory", missing.path
        ]) { root }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingOptions.stateDirectory.path))

        let insecure = try makeDirectory(in: root, name: "insecure", mode: 0o755)
        let insecureOptions = try applicationLaunchOptions(arguments: [
            "--verify-external-handoff", "--allow-display-write", "--state-directory", insecure.path
        ]) { root }
        XCTAssertThrowsError(try RecoveryStore(directory: insecureOptions.stateDirectory)) { error in
            XCTAssertEqual(error as? RecoveryStoreError, .insecureDirectory)
        }
        XCTAssertEqual(try permissions(at: insecure), 0o755)
    }

    @MainActor
    func testExternalHandoffPreferencesAreIsolatedAndRebuiltForSameDirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateDirectory = try makeDirectory(in: root, name: "state", mode: 0o700)
        let arguments = ["--verify-external-handoff", "--allow-display-write", "--state-directory", stateDirectory.path]
        let launchOptions = try applicationLaunchOptions(arguments: arguments) { root }
        let suiteName = applicationPreferenceSuiteName(for: launchOptions.stateDirectory)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let standard = UserDefaults.standard
        let standardMode = standard.object(forKey: "explicitDisplayMode.v1") as? NSObject
        let standardHandoff = standard.object(forKey: "externalHandoffRequested.v1") as? NSObject
        let preferences = DisplayModePreferences(defaults: defaults)
        try preferences.select(.internalOnly)
        try preferences.setExternalHandoffRequested(true)
        let inputSettings = ExternalDisplayInputSettings(defaults: defaults)
        XCTAssertEqual(inputSettings.inputOptions, [])
        XCTAssertFalse(inputSettings.automaticInputEnabled)

        let restarted = try externalHandoffLaunchPreferences(for: launchOptions.stateDirectory)
        XCTAssertEqual(restarted.preferences.selectedMode, .internalOnly)
        XCTAssertTrue(restarted.preferences.externalHandoffRequested)
        XCTAssertFalse(ExternalDisplayInputSettings(defaults: restarted.defaults).automaticInputEnabled)
        XCTAssertEqual(standard.object(forKey: "explicitDisplayMode.v1") as? NSObject, standardMode)
        XCTAssertEqual(standard.object(forKey: "externalHandoffRequested.v1") as? NSObject, standardHandoff)

        let freshDirectory = try makeDirectory(in: root, name: "fresh-state", mode: 0o700)
        let freshSuiteName = applicationPreferenceSuiteName(for: freshDirectory)
        let fresh = try externalHandoffLaunchPreferences(for: freshDirectory)
        defer { fresh.defaults.removePersistentDomain(forName: freshSuiteName) }
        var factoryCalls = 0
        let coordinator = try DisplayModeCoordinator(
            directory: freshDirectory,
            preferences: fresh.preferences,
            availableModes: [.externalPrimary, .internalOnly],
            inputSettings: ExternalDisplayInputSettings(defaults: fresh.defaults)
        ) { _, _, _ in
            factoryCalls += 1
            throw RecoveryStoreError.ioFailure
        }
        coordinator.startApplication(registerEvents: false, recoveryOnly: false) { _ in }
        XCTAssertNil(coordinator.selectedMode)
        XCTAssertFalse(fresh.preferences.externalHandoffRequested)
        XCTAssertEqual(factoryCalls, 0)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExtilumeApplicationLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func makeDirectory(in parent: URL, name: String, mode: Int) throws -> URL {
        let directory = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: mode])
        return directory
    }

    private func permissions(at url: URL) throws -> Int? {
        let value = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        return value.map { $0.intValue & 0o7777 }
    }
}
