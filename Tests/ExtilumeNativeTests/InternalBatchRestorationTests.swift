import Darwin
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class InternalBatchRestorationTests: XCTestCase {
    private var root: URL!
    private var budget: InternalDisableBatchBudget!
    private let boot = UUID()
    private let timestamp: UInt64 = 200

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        try LayoutCloseoutDirectory(root.path).write("policy.json", value:
            InternalDisableBatchBudget.Policy(bootSession: boot, started: 100, deadline: 1000))
        budget = try InternalDisableBatchBudget(path: root.path, now: { self.timestamp }, boot: { self.boot })
        try budget.registerProcess(role: "app", pid: getpid())
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func record() throws -> RecoveryRecord {
        let internalID = UUID(), externalID = UUID()
        let baseline = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0), externalID: DisplayOrigin(x: 1920, y: 0)
        ])
        let target = try internalApplicationTargetLayout(for: baseline, externalIdentity: externalID)
        return try RecoveryRecord(baseline: baseline, target: target,
            internalDisplay: InternalDisplayResponsibility(identity: internalID, baseline: true, applied: false,
                hardwareIdentity: InternalDisplayHardwareIdentity(bootSession: boot, registryEntryID: 1),
                numericIDHint: 1))
    }

    private func restored(_ record: RecoveryRecord, verified: Bool = true) throws -> RecoveryRecord {
        var result = record
        result.beginRestoration()
        try result.confirmRestored(actual: result.baseline, internalEnabled: true)
        if verified { try result.confirmIndependentGuardVerification() }
        return result
    }

    private var receiptURL: URL { root.appendingPathComponent("restoration.json") }

    func testReceiptContainsVerifiedRecordAndCurrentProcessAndCannotBeOverwritten() throws {
        let original = try record()
        let expectation = try InternalApplicationExpectation(record: original)
        let recovered = try restored(original)
        try LayoutCloseoutDirectory(root.path).write("stopped", data: Data())

        try budget.recordRestoration(recovered, expectation: expectation)

        let data = try Data(contentsOf: receiptURL)
        let receipt = try JSONDecoder().decode(InternalDisableBatchBudget.RestorationReceipt.self, from: data)
        XCTAssertEqual(receipt.version, 1)
        XCTAssertEqual(receipt.app, try ApplicationAutomationTarget.read(pid: getpid()))
        XCTAssertEqual(receipt.verifiedAtNanoseconds, timestamp)
        XCTAssertEqual(receipt.expectation, expectation)
        XCTAssertEqual(receipt.record, recovered)
        let attributes = try FileManager.default.attributesOfItem(atPath: receiptURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try budget.recordRestoration(recovered, expectation: expectation))
        XCTAssertEqual(try Data(contentsOf: receiptURL), data)
    }

    func testPendingRecordAndMissingIndependentVerificationAreRejected() throws {
        let original = try record()
        let expectation = try InternalApplicationExpectation(record: original)
        XCTAssertThrowsError(try budget.recordRestoration(original, expectation: expectation))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertThrowsError(try budget.recordRestoration(restored(original, verified: false), expectation: expectation))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
    }

    func testMismatchedExpectationIsRejected() throws {
        let recovered = try restored(record())
        let other = try InternalApplicationExpectation(record: record())
        XCTAssertThrowsError(try budget.recordRestoration(recovered, expectation: other))
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
    }
}
