import Foundation
import XCTest
@testable import ExtilumeNative

private final class SessionSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [RecoverySessionSignal] = []
    func append(_ signal: RecoverySessionSignal) {
        lock.lock(); defer { lock.unlock() }
        values.append(signal)
    }
    var snapshot: [RecoverySessionSignal] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

final class RecoverySessionNotificationsTests: XCTestCase {
    func testOnlyKnownNamesAreObservedAndStopRemovesObservers() {
        let center = NotificationCenter()
        let signals = SessionSignals()
        let observer = RecoverySessionNotifications(center: center, observe: { signals.append($0) })
        center.post(name: Notification.Name("unrecognized"), object: nil)
        for signal in RecoverySessionSignal.allCases {
            center.post(name: signal.name, object: "PRIVATE_OBJECT", userInfo: ["private": "PRIVATE_PAYLOAD"])
        }
        XCTAssertEqual(signals.snapshot, RecoverySessionSignal.allCases)
        observer.stop()
        observer.stop()
        center.post(name: RecoverySessionSignal.screenUnlockedNotificationReceived.name, object: nil)
        XCTAssertEqual(signals.snapshot, RecoverySessionSignal.allCases)
    }

    func testMarkerDescribesReceptionAndNeverClaimsUnlockCompletion() throws {
        let line = try recoverySessionNotificationMarker(.screenUnlockedNotificationReceived, receivedAt: 123)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        XCTAssertEqual(Set(value.keys), ["type", "source", "clock", "signal", "receivedAtNanoseconds"])
        XCTAssertEqual(value["source"] as? String, "unverified-distributed-notification")
        XCTAssertEqual(value["signal"] as? String, "screenUnlockedNotificationReceived")
        XCTAssertEqual(value["receivedAtNanoseconds"] as? UInt64, 123)
        XCTAssertFalse(line.contains("PRIVATE"))
    }

    func testImmediateEOFAndStopBothFinishMainRunLoop() throws {
        XCTAssertTrue(Thread.isMainThread)
        for command: String? in [nil, " stop\n"] {
            try waitForRecoveryRecorderStop { command }
        }
    }
}
