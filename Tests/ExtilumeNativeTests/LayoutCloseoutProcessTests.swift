import Darwin
import XCTest
@testable import ExtilumeNative

final class LayoutCloseoutProcessTests: XCTestCase {
    private let selfPID: pid_t = 101
    private let otherPID: pid_t = 202

    func testListFailuresHaveDistinctCodesAndDoNotReadImages() {
        for sizing: Int32 in [0, -1] {
            XCTAssertThrowsError(try checkLayoutCloseoutProcesses(currentPID: selfPID, list: { _, _ in sizing }, image: { _ in
                XCTFail("image should not be queried")
                return nil
            }, isGone: { _ in false }, isOwnWitness: { _, _ in false })) { error in
                XCTAssertEqual(layoutCloseoutFailureCode(error), "closeout-processListSizing")
            }
        }
        for variant in 0..<3 {
            XCTAssertThrowsError(try checkLayoutCloseoutProcesses(currentPID: selfPID, list: { buffer, capacity in
                if buffer == nil { return Int32(MemoryLayout<pid_t>.size) }
                return variant == 0 ? 0 : variant == 1 ? -1 : capacity
            }, image: { _ in
                XCTFail("image should not be queried")
                return nil
            }, isGone: { _ in false }, isOwnWitness: { _, _ in false })) { error in
                XCTAssertEqual(layoutCloseoutFailureCode(error), "closeout-processListRead")
            }
        }
    }

    func testMissingImageStopsUnlessProcessIsGone() throws {
        for gone in [false, true] {
            var imageReads = 0
            var goneChecks = 0
            let check = {
                try checkLayoutCloseoutProcesses(currentPID: self.selfPID, list: self.list([self.otherPID]), image: { _ in
                    imageReads += 1
                    return nil
                }, isGone: { _ in
                    goneChecks += 1
                    return gone
                }, isOwnWitness: { _, _ in
                    XCTFail("missing image cannot be accepted as witness")
                    return true
                })
            }
            if gone { do { try check() } catch { XCTFail("gone process should be skipped") } }
            else {
                XCTAssertThrowsError(try check()) { error in
                    XCTAssertEqual(layoutCloseoutFailureCode(error), "closeout-processImageUnavailable")
                }
            }
            XCTAssertEqual(imageReads, 1)
            XCTAssertEqual(goneChecks, 1)
        }
    }

    func testSkipsSelfNonpositiveAndUnrelatedImages() throws {
        var imageReads = 0
        try checkLayoutCloseoutProcesses(currentPID: selfPID, list: list([0, -1, selfPID, otherPID]), image: { _ in
            imageReads += 1
            return "/synthetic/unrelated"
        }, isGone: { _ in XCTFail("image is available"); return false }, isOwnWitness: { _, _ in
            XCTFail("unrelated image should not be checked as witness")
            return false
        })
        XCTAssertEqual(imageReads, 1)
    }

    func testKnownImagesRequireOwnWitness() {
        for name in ["Extilume", "extilume-probe", "native-primary-preparation"] {
            for own in [false, true] {
                var checks = 0
                let check = {
                    try checkLayoutCloseoutProcesses(currentPID: self.selfPID, list: self.list([self.otherPID]), image: { _ in
                        "/synthetic/\(name)"
                    }, isGone: { _ in XCTFail("image is available"); return false }, isOwnWitness: { _, _ in
                        checks += 1
                        return own
                    })
                }
                if own { do { try check() } catch { XCTFail("own witness should be allowed") } }
                else {
                    XCTAssertThrowsError(try check()) { error in
                        XCTAssertEqual(layoutCloseoutFailureCode(error), "closeout-controllerPresent")
                    }
                }
                XCTAssertEqual(checks, 1)
            }
        }
    }

    private func list(_ pids: [pid_t]) -> (UnsafeMutableRawPointer?, Int32) -> Int32 {
        { buffer, capacity in
            let byteCount = pids.count * MemoryLayout<pid_t>.size
            guard let buffer else { return Int32(byteCount) }
            guard byteCount <= Int(capacity) else { return capacity }
            pids.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress { buffer.copyMemory(from: base, byteCount: byteCount) }
            }
            return Int32(byteCount)
        }
    }
}
