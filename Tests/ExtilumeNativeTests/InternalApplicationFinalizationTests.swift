import Darwin
import Foundation
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

final class InternalApplicationFinalizationTests: XCTestCase {
    func testFaultCannotBeClearedBySuccessfulStopOrAnotherQuitRequest() {
        var gate = InternalApplicationFinalization()
        let request = gate.beginQuit()
        gate.noteStopped(faulted: false)
        XCTAssertTrue(gate.permitsClear(request: request, recoveryOnly: false, workerSucceeded: true, transportFailed: false))
        gate.noteFault()
        gate.noteStopped(faulted: false)
        XCTAssertFalse(gate.permitsClear(request: request, recoveryOnly: false, workerSucceeded: true, transportFailed: false))
        let retry = gate.beginQuit()
        XCTAssertFalse(gate.permitsClear(request: retry, recoveryOnly: true, workerSucceeded: true, transportFailed: false))
    }

    func testCancelledOrSupersededVerificationCannotClearRecord() {
        var gate = InternalApplicationFinalization()
        let first = gate.beginQuit()
        gate.noteStopped(faulted: false)
        gate.cancelQuit()
        XCTAssertFalse(gate.permitsClear(request: first, recoveryOnly: false, workerSucceeded: true, transportFailed: false))
        let second = gate.beginQuit()
        XCTAssertFalse(gate.permitsClear(request: first, recoveryOnly: false, workerSucceeded: true, transportFailed: false))
        XCTAssertTrue(gate.permitsClear(request: second, recoveryOnly: false, workerSucceeded: true, transportFailed: false))
        XCTAssertFalse(gate.permitsClear(request: second, recoveryOnly: false, workerSucceeded: true, transportFailed: true))
    }

    func testNormalExitRequiresExplicitStopConfirmation() {
        var gate = InternalApplicationFinalization()
        let request = gate.beginQuit()
        XCTAssertFalse(gate.permitsClear(request: request, recoveryOnly: false, workerSucceeded: true, transportFailed: false))
        XCTAssertTrue(gate.permitsClear(request: request, recoveryOnly: true, workerSucceeded: true, transportFailed: false))
        gate.noteStopped(faulted: true)
        XCTAssertFalse(gate.permitsClear(request: request, recoveryOnly: true, workerSucceeded: true, transportFailed: false))
    }

    func testBlockedStartCannotCommitAfterStopOrBufferedPeerClosure() throws {
        for scenario in ["stop", "buffered-close"] {
            var descriptors: [Int32] = [-1, -1]
            XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors), 0)
            let channel = try GuardChannel(descriptor: descriptors[0])
            var peer = descriptors[1]
            defer { if peer >= 0 { close(peer) } }
            let state = InternalApplicationWorkerState(channel: channel, onFinish: {})
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let finished = expectation(description: scenario)
            let commits = Counter()
            let parent = getppid()
            DispatchQueue.global().async {
                entered.signal()
                if release.wait(timeout: .now() + 2) == .success {
                    do { try state.checkAccess(parentPID: parent); commits.increment() }
                    catch {}
                }
                finished.fulfill()
            }
            XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
            if scenario == "stop" { state.requestStop() }
            else {
                var partial: UInt8 = 0
                XCTAssertEqual(Darwin.send(peer, &partial, 1, 0), 1)
                close(peer)
                peer = -1
            }
            release.signal()
            wait(for: [finished], timeout: 3)
            XCTAssertEqual(commits.value, 0)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.withLock { count += 1 } }
        var value: Int { lock.withLock { count } }
    }
}
