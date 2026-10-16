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

        let result = try applicationStateDirectory(arguments: ["--state-directory", customPath.path]) {
            supportCalls += 1
            return root
        }

        XCTAssertEqual(result, customPath)
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
            ["--state-directory", "/one", "--state-directory", "/two"]
        ]
        var supportCalls = 0

        for arguments in invalidArguments {
            XCTAssertThrowsError(try applicationStateDirectory(arguments: arguments) {
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

        let result = try applicationStateDirectory(arguments: []) { support }

        XCTAssertEqual(result, support.appendingPathComponent("Extilume", isDirectory: true))
        XCTAssertEqual(try permissions(at: result), 0o700)
    }

    func testExistingDirectoryPermissionsAndContentsAreUnchanged() throws {
        let support = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let stateDirectory = try makeDirectory(in: support, name: "Extilume", mode: 0o755)
        let sentinel = stateDirectory.appendingPathComponent("keep.txt")
        let contents = Data("keep existing state".utf8)
        try contents.write(to: sentinel)

        let result = try applicationStateDirectory(arguments: []) { support }

        XCTAssertEqual(result, stateDirectory)
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

        let result = try applicationStateDirectory(arguments: []) { support }

        XCTAssertEqual(result, stateLink)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: stateLink.path), target.path)
        XCTAssertEqual(try permissions(at: target), 0o755)
        XCTAssertEqual(try Data(contentsOf: sentinel), contents)
    }

    func testSupportDirectoryFailurePropagates() throws {
        enum ExpectedFailure: Error { case lookup }

        XCTAssertThrowsError(try applicationStateDirectory(arguments: []) {
            throw ExpectedFailure.lookup
        }) { error in
            XCTAssertTrue(error is ExpectedFailure)
        }
    }

    func testMissingSupportParentReturnsStaticCreationError() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missingSupport = root.appendingPathComponent("missing-support", isDirectory: true)

        XCTAssertThrowsError(try applicationStateDirectory(arguments: []) { missingSupport }) { error in
            XCTAssertEqual(error as? RecoveryStoreError, .ioFailure)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingSupport.appendingPathComponent("Extilume").path))
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
