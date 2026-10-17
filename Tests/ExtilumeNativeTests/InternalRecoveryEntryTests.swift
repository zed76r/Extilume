import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class InternalRecoveryEntryTests: XCTestCase {
    func testMissingResponsibilityRefusesBeforeDisplayReads() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try recoverInternalRecord(directory: directory)) { error in
            guard case RecoveryError.invalidRecord = error else { return XCTFail("wrong refusal") }
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testPrimaryOnlyResponsibilityIsRetainedAndRefused() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let display = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
        let layout = try DisplayLayout(main: display, origins: [display: DisplayOrigin(x: 0, y: 0)])
        do {
            let store = try RecoveryStore(directory: directory)
            try store.acquireExclusiveOwnership()
            try store.save(RecoveryRecord(baseline: layout, target: layout))
        }
        let recordURL = directory.appendingPathComponent("recovery-record.json")
        let before = try Data(contentsOf: recordURL)
        XCTAssertThrowsError(try recoverInternalRecord(directory: directory)) { error in
            guard case RecoveryError.invalidRecord = error else { return XCTFail("wrong refusal") }
        }
        XCTAssertEqual(try Data(contentsOf: recordURL), before)
    }
}
