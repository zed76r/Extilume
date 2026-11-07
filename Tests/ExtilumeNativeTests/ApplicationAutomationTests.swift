import XCTest
import Darwin
@testable import ExtilumeNative

final class ApplicationAutomationTests: XCTestCase {
    func testOlderRepliesKeepUnknownStructuredState() throws {
        let data = Data(#"{"result":"status","status":"旧版状态","actions":[]}"#.utf8)
        let reply = try JSONDecoder().decode(ApplicationAutomationReply.self, from: data)
        XCTAssertNil(reply.sessionState)
        XCTAssertNil(reply.selectedMode)
        XCTAssertNil(reply.stateMode)
        XCTAssertNil(reply.requiresExplicitActivation)
    }

    func testStatusNeedsNoWriteAuthorization() throws {
        let options = try ApplicationAutomationOptions(arguments: ["--control", "status"])
        XCTAssertEqual(options.request.action, "status")
        XCTAssertFalse(options.request.allowDisplayWrite)
        XCTAssertEqual(options.bundleID, "com.extilume.development")
    }

    func testMutationRequiresExplicitFlag() throws {
        XCTAssertThrowsError(try ApplicationAutomationOptions(arguments: ["--control", "apply-externalOnly"]))
        let options = try ApplicationAutomationOptions(arguments: ["--control", "apply-externalOnly", "--allow-display-write", "--bundle-id", "test.app"])
        XCTAssertTrue(options.request.allowDisplayWrite)
        XCTAssertEqual(options.bundleID, "test.app")
    }

    func testTargetBindingParsesWithoutGrantingWritePermission() throws {
        let target = try ApplicationAutomationTarget(parsing: "123:456:789")
        let options = try ApplicationAutomationOptions(arguments: ["--control", "status", "--target-process", "123:456:789", "--bundle-id", "test.app"])
        XCTAssertEqual(options.request.target, target)
        XCTAssertFalse(options.request.allowDisplayWrite)
        XCTAssertThrowsError(try ApplicationAutomationOptions(arguments: ["--control", "apply-externalOnly", "--target-process", "123:456:789"]))
        for value in ["", "1:2:3", "123:0:0", "123:1:1000000", "123:1", "123:1:2:3", "-1:1:1", "2147483648:1:1", "123:+1:1"] {
            XCTAssertThrowsError(try ApplicationAutomationTarget(parsing: value))
        }
    }

    func testTargetRejectsReusedPIDAndDifferentBuildPath() throws {
        let target = try ApplicationAutomationTarget(parsing: "123:456:789")
        let image = URL(fileURLWithPath: "/candidate/Extilume")
        try target.validate(processID: 123, executable: image, clientExecutable: image, read: { _ in target })
        XCTAssertThrowsError(try target.validate(processID: 123, executable: image, clientExecutable: image,
            read: { _ in try ApplicationAutomationTarget(parsing: "123:456:790") }))
        XCTAssertThrowsError(try target.validate(processID: 124, executable: image, clientExecutable: image,
            read: { _ in XCTFail("must reject before reading"); return target }))
        XCTAssertThrowsError(try target.validate(processID: 123, executable: URL(fileURLWithPath: "/daily/Extilume"), clientExecutable: image,
            read: { _ in XCTFail("must reject before reading"); return target }))
    }

    func testTargetReadsCurrentKernelIdentity() throws {
        let first = try ApplicationAutomationTarget.read(pid: getpid())
        XCTAssertEqual(first.pid, getpid())
        XCTAssertEqual(try ApplicationAutomationTarget.read(pid: getpid()), first)
        XCTAssertGreaterThan(first.startSeconds, 0)
        XCTAssertLessThan(first.startMicroseconds, 1_000_000)
    }

    func testMalformedArgumentsFailClosed() {
        for args in [[], ["--control"], ["--control", "--allow-display-write"],
                     ["--control", "status", "--unknown"], ["--control", "status", "--bundle-id"],
                     ["--control", "status", "--bundle-id", ""],
                     ["--control", "status", "--allow-display-write", "--allow-display-write"]] {
            XCTAssertThrowsError(try ApplicationAutomationOptions(arguments: args))
        }
    }
}
