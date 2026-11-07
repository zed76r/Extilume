import Darwin
import Foundation
import XCTest
@testable import ExtilumeNative

final class InternalDisableBatchBudgetTests: XCTestCase {
    private var root: URL!
    private var boot: UUID!
    private var time: UInt64 = 100

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        boot = UUID()
        try LayoutCloseoutDirectory(root.path).write("policy.json", value:
            InternalDisableBatchBudget.Policy(bootSession: boot, started: 100, deadline: 180_000_000_100))
        try LayoutCloseoutDirectory(root.path).write("initial-authorized.json", value: UInt64(100))
        try LayoutCloseoutDirectory(root.path).write("wake-authorized.json", value: UInt64(150))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }
    private func budget() throws -> InternalDisableBatchBudget {
        try InternalDisableBatchBudget(path: root.path, now: { self.time }, boot: { self.boot })
    }
    private func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path)
    }
    func testProcessRegistrationUsesCurrentKernelIdentityAndIsExclusive() throws {
        let gate = try budget()
        try gate.registerProcess(role: "app", pid: getpid())
        let bytes = try LayoutCloseoutDirectory(root.path).read("app-process.json")
        XCTAssertEqual(try JSONDecoder().decode(ApplicationAutomationTarget.self, from: bytes),
                       try ApplicationAutomationTarget.read(pid: getpid()))
        XCTAssertThrowsError(try gate.registerProcess(role: "app", pid: getpid()))
        XCTAssertThrowsError(try gate.registerProcess(role: "../other", pid: getpid()))
        XCTAssertEqual(try LayoutCloseoutDirectory(root.path).read("app-process.json"), bytes)
    }

    func testProcessReceiptIsInvisibleUntilCompleteAndIdentityRechecked() throws {
        let gate = try budget()
        var reads = 0
        try gate.registerProcess(role: "app", pid: getpid()) { pid in
            reads += 1
            if reads == 2 {
                XCTAssertFalse(self.exists("app-process.json"))
                let staged = try LayoutCloseoutDirectory(self.root.path).read(".app-process.pending")
                XCTAssertEqual(try JSONDecoder().decode(ApplicationAutomationTarget.self, from: staged),
                               try ApplicationAutomationTarget.read(pid: pid))
            }
            return try ApplicationAutomationTarget.read(pid: pid)
        }
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(exists("app-process.json"))
    }

    func testInitialAndOneWakeAttemptAreDurableAndThirdIsRejected() throws {
        let gate = try budget()
        try gate.consume(wakeAt: nil)
        XCTAssertTrue(exists("initial-consumed.json"))
        time = 200
        try gate.consume(wakeAt: 150)
        XCTAssertTrue(exists("wake-consumed.json"))
        XCTAssertThrowsError(try gate.consume(wakeAt: 150))
        XCTAssertTrue(exists("stopped"))
    }
    func testRestartCannotReclaimInitialSlot() throws {
        try budget().consume(wakeAt: nil)
        XCTAssertThrowsError(try budget().consume(wakeAt: nil))
    }
    func testManualReapplyConsumesNoWakeSlotAndLatchesStop() throws {
        let gate = try budget()
        try gate.consume(wakeAt: nil)
        XCTAssertThrowsError(try gate.consume(wakeAt: nil))
        time = 200
        XCTAssertThrowsError(try gate.consume(wakeAt: 150))
        XCTAssertFalse(exists("wake-consumed.json"))
    }
    func testWakeBeforeInitialAttemptIsRejected() throws {
        XCTAssertThrowsError(try budget().consume(wakeAt: 100))
        XCTAssertFalse(exists("initial-consumed.json"))
    }
    func testOriginalDeadlineAndClockRegressionRejectBeforeConsumption() throws {
        let gate = try budget()
        time = 180_000_000_100
        XCTAssertThrowsError(try gate.consume(wakeAt: nil))
        time = 99
        XCTAssertThrowsError(try gate.consume(wakeAt: nil))
        XCTAssertFalse(exists("initial-consumed.json"))
    }
    func testWakeDeadlineDoesNotRenewTotalWindow() throws {
        let gate = try budget()
        try gate.consume(wakeAt: nil)
        time = 10_000_000_200
        XCTAssertThrowsError(try gate.consume(wakeAt: 200))
        XCTAssertFalse(exists("wake-consumed.json"))
    }
    func testWrongBootAndMalformedConfigurationFailClosed() throws {
        XCTAssertThrowsError(try InternalDisableBatchBudget(path: root.path, boot: { UUID() }))
        XCTAssertThrowsError(try InternalDisableBatchBudget.configured(environment:
            [InternalDisableBatchBudget.environmentKey: ""]))
        XCTAssertNil(try InternalDisableBatchBudget.configured(environment: [:]))
    }
    func testSymlinkCannotStandInForConsumptionFile() throws {
        let target = root.appendingPathComponent("untouched")
        try Data("original".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("initial-consumed.json"),
                                                   withDestinationURL: target)
        XCTAssertThrowsError(try budget().consume(wakeAt: nil))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
    }
    func testExternalStopPreventsNewAttempt() throws {
        let gate = try budget()
        try LayoutCloseoutDirectory(root.path).write("stopped", data: Data())
        XCTAssertThrowsError(try gate.consume(wakeAt: nil))
        XCTAssertFalse(exists("initial-consumed.json"))
    }
    func testMissingRequestPermitPreventsAutomaticStartup() throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent("initial-authorized.json"))
        XCTAssertThrowsError(try budget().consume(wakeAt: nil))
        XCTAssertFalse(exists("initial-consumed.json"))
    }
    func testPolicyMutationIsRejected() throws {
        let gate = try budget()
        try Data("{}".utf8).write(to: root.appendingPathComponent("policy.json"))
        XCTAssertThrowsError(try gate.consume(wakeAt: nil))
        XCTAssertFalse(exists("initial-consumed.json"))
    }
    func testWakeBeforeSleepPermitIsRejected() throws {
        let gate = try budget()
        try gate.consume(wakeAt: nil)
        time = 200
        XCTAssertThrowsError(try gate.consume(wakeAt: 140))
        XCTAssertFalse(exists("wake-consumed.json"))
    }
    func testSlowDurableConsumptionCannotStartDisplayWorkAfterDeadline() throws {
        var reads = 0
        let gate = try InternalDisableBatchBudget(path: root.path, now: {
            reads += 1
            return reads == 1 ? 100 : 180_000_000_100
        }, boot: { self.boot })
        XCTAssertThrowsError(try gate.consume(wakeAt: nil))
        XCTAssertTrue(exists("initial-consumed.json"))
        XCTAssertTrue(exists("stopped"))
    }
}
