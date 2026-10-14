import Dispatch
import XCTest
@testable import ExtilumeCore

final class PrimaryReapplicationSchedulerTests: XCTestCase {
    func testBurstRunsOnlyLatestActionAfterDelay() {
        let ownerQueue = DispatchQueue(label: "PrimaryReapplicationSchedulerTests.owner")
        let scheduler = PrimaryReapplicationScheduler(ownerQueue: ownerQueue)
        let firstAction = DispatchSemaphore(value: 0)
        let secondAction = DispatchSemaphore(value: 0)
        let latestAction = DispatchSemaphore(value: 0)
        let latestActionSawNoPending = DispatchSemaphore(value: 0)

        ownerQueue.sync {
            scheduler.schedule { _ in firstAction.signal() }
            scheduler.schedule { _ in secondAction.signal() }
            scheduler.schedule { _ in
                if !scheduler.hasPending { latestActionSawNoPending.signal() }
                latestAction.signal()
            }
            XCTAssertTrue(scheduler.hasPending)
        }

        XCTAssertEqual(firstAction.wait(timeout: .now() + 0.05), .timedOut)
        XCTAssertEqual(latestAction.wait(timeout: .now() + 1.5), .success)
        XCTAssertEqual(latestActionSawNoPending.wait(timeout: .now()), .success)
        XCTAssertEqual(firstAction.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(secondAction.wait(timeout: .now()), .timedOut)
    }

    func testCancelStopsScheduledAction() {
        let ownerQueue = DispatchQueue(label: "PrimaryReapplicationSchedulerTests.cancel")
        let scheduler = PrimaryReapplicationScheduler(ownerQueue: ownerQueue)
        let action = DispatchSemaphore(value: 0)

        ownerQueue.sync {
            scheduler.schedule { _ in action.signal() }
            XCTAssertTrue(scheduler.hasPending)
            scheduler.cancel()
            XCTAssertFalse(scheduler.hasPending)
        }

        XCTAssertEqual(action.wait(timeout: .now() + 1.5), .timedOut)
    }

    func testIncomingEventInvalidatesActionWhileOwnerQueueIsBlocked() {
        let ownerQueue = DispatchQueue(label: "PrimaryReapplicationSchedulerTests.blocked")
        let scheduler = PrimaryReapplicationScheduler(ownerQueue: ownerQueue)
        let enteredReadback = DispatchSemaphore(value: 0)
        let resumeReadback = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let configured = DispatchSemaphore(value: 0)
        ownerQueue.sync {
            scheduler.schedule { isCurrent in
                enteredReadback.signal()
                guard resumeReadback.wait(timeout: .now() + 2) == .success else { return }
                if isCurrent() { configured.signal() }
                finished.signal()
            }
        }
        XCTAssertEqual(enteredReadback.wait(timeout: .now() + 1.5), .success)
        scheduler.invalidate()
        resumeReadback.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(configured.wait(timeout: .now()), .timedOut)
    }

    func testInvalidatedPendingActionIsClearedWithoutExecuting() {
        let ownerQueue = DispatchQueue(label: "PrimaryReapplicationSchedulerTests.invalidated")
        let scheduler = PrimaryReapplicationScheduler(ownerQueue: ownerQueue)
        let action = DispatchSemaphore(value: 0)
        let cleared = DispatchSemaphore(value: 0)
        ownerQueue.sync { scheduler.schedule { _ in action.signal() } }
        scheduler.invalidate()
        ownerQueue.asyncAfter(deadline: .now() + 1.2) {
            if !scheduler.hasPending { cleared.signal() }
        }
        XCTAssertEqual(cleared.wait(timeout: .now() + 1.5), .success)
        XCTAssertEqual(action.wait(timeout: .now()), .timedOut)
    }
}
