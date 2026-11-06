import XCTest
@testable import ExtilumeNative

final class ApplicationAutomationTests: XCTestCase {
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

    func testMalformedArgumentsFailClosed() {
        for args in [[], ["--control"], ["--control", "--allow-display-write"],
                     ["--control", "status", "--unknown"], ["--control", "status", "--bundle-id"],
                     ["--control", "status", "--bundle-id", ""],
                     ["--control", "status", "--allow-display-write", "--allow-display-write"]] {
            XCTAssertThrowsError(try ApplicationAutomationOptions(arguments: args))
        }
    }
}
