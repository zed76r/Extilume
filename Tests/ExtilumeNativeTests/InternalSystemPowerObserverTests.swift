import XCTest
@testable import ExtilumeNative

final class InternalSystemPowerObserverTests: XCTestCase {
    func testAcknowledgementMarkersBracketOneAckAfterPreparation() {
        for active in [true, false] {
            for acknowledged in [true, false] {
                var events: [String] = []
                InternalSystemPowerObserver.dispatchMessage(
                    InternalSystemPowerMessage.systemWillSleep, notificationID: 47, active: active,
                    prepareForSleep: { events.append("prepare"); return false },
                    acknowledge: { id in
                        XCTAssertEqual(id, 47)
                        events.append("ack")
                        return acknowledged
                    },
                    didPrepareForSleep: { restored, result in
                        XCTAssertFalse(restored)
                        XCTAssertEqual(result, acknowledged)
                        events.append("complete")
                    },
                    didWake: { XCTFail("sleep must not wake") },
                    trace: { stage, result in
                        if stage == .powerAcknowledgementStarted { XCTAssertNil(result) }
                        else { XCTAssertEqual(result, acknowledged) }
                        events.append(stage.rawValue)
                    },
                    onFailure: { events.append("failure") }
                )
                var expected = active ? ["prepare"] : []
                expected += ["powerAcknowledgementStarted", "ack", "powerAcknowledgementFinished"]
                if active { expected.append("complete") }
                if !acknowledged { expected.append("failure") }
                XCTAssertEqual(events, expected)
            }
        }
    }

    func testWillSleepPreparesAcknowledgesThenCompletes() {
        var events: [String] = []
        var acknowledgedIDs: [Int] = []

        dispatch(InternalSystemPowerMessage.systemWillSleep, notificationID: 41,
                 prepare: { events.append("prepare"); return true },
                 acknowledge: { acknowledgedIDs.append($0); events.append("ack"); return true },
                 didPrepare: { events.append("complete:\($0):\($1)") },
                 didWake: { events.append("wake") },
                 onFailure: { events.append("failure") })

        XCTAssertEqual(events, ["prepare", "ack", "complete:true:true"])
        XCTAssertEqual(acknowledgedIDs, [41])
    }

    func testWillSleepPreparationTimeoutStillAcknowledgesAndCompletesFalse() {
        var events: [String] = []
        var acknowledgedIDs: [Int] = []

        dispatch(InternalSystemPowerMessage.systemWillSleep, notificationID: 42,
                 prepare: { events.append("prepare"); return false },
                 acknowledge: { acknowledgedIDs.append($0); events.append("ack"); return true },
                 didPrepare: { events.append("complete:\($0):\($1)") },
                 didWake: { events.append("wake") },
                 onFailure: { events.append("failure") })

        XCTAssertEqual(events, ["prepare", "ack", "complete:false:true"])
        XCTAssertEqual(acknowledgedIDs, [42])
    }

    func testWillSleepAcknowledgementFailureIsReportedAfterSingleAckAndCompletion() {
        var events: [String] = []
        var acknowledgedIDs: [Int] = []

        dispatch(InternalSystemPowerMessage.systemWillSleep, notificationID: 43,
                 prepare: { events.append("prepare"); return true },
                 acknowledge: { acknowledgedIDs.append($0); events.append("ack"); return false },
                 didPrepare: { events.append("complete:\($0):\($1)") },
                 didWake: { events.append("wake") },
                 onFailure: { events.append("failure") })

        XCTAssertEqual(events, ["prepare", "ack", "complete:true:false", "failure"])
        XCTAssertEqual(acknowledgedIDs, [43])
    }

    func testCanSystemSleepIsAcknowledgedDirectlyAndReportsFailure() {
        var events: [String] = []
        var acknowledgedIDs: [Int] = []

        dispatch(InternalSystemPowerMessage.canSystemSleep, notificationID: 44,
                 prepare: { events.append("prepare"); return true },
                 acknowledge: { acknowledgedIDs.append($0); events.append("ack"); return false },
                 didPrepare: { _, _ in events.append("complete") },
                 didWake: { events.append("wake") },
                 onFailure: { events.append("failure") })

        XCTAssertEqual(events, ["ack", "failure"])
        XCTAssertEqual(acknowledgedIDs, [44])
    }

    func testOnlyHasPoweredOnReportsWakeAndNonAckMessagesAreIgnored() {
        var events: [String] = []
        var acknowledgedIDs: [Int] = []
        let messages = [
            InternalSystemPowerMessage.systemWillPowerOn,
            InternalSystemPowerMessage.systemWillNotSleep,
            UInt32.max,
        ]

        for message in messages {
            dispatch(message, notificationID: 45,
                     prepare: { events.append("prepare"); return true },
                     acknowledge: { acknowledgedIDs.append($0); events.append("ack"); return true },
                     didPrepare: { _, _ in events.append("complete") },
                     didWake: { events.append("wake") },
                     onFailure: { events.append("failure") })
        }
        dispatch(InternalSystemPowerMessage.systemHasPoweredOn, notificationID: 46,
                 prepare: { events.append("prepare"); return true },
                 acknowledge: { acknowledgedIDs.append($0); events.append("ack"); return true },
                 didPrepare: { _, _ in events.append("complete") },
                 didWake: { events.append("wake") },
                 onFailure: { events.append("failure") })

        XCTAssertEqual(events, ["wake"])
        XCTAssertTrue(acknowledgedIDs.isEmpty)
    }

    func testInactiveObserverAcknowledgesLateSleepWithoutPreparingOrWaking() {
        var events: [String] = []
        var acknowledgedIDs: [Int] = []

        dispatch(InternalSystemPowerMessage.canSystemSleep, notificationID: 46, active: false,
                 prepare: { events.append("prepare"); return true },
                 acknowledge: { acknowledgedIDs.append($0); events.append("ack"); return true },
                 didPrepare: { _, _ in events.append("complete") },
                 didWake: { events.append("wake") },
                 onFailure: { events.append("failure") })
        dispatch(InternalSystemPowerMessage.systemWillSleep, notificationID: 47, active: false,
                 prepare: { events.append("prepare"); return true },
                 acknowledge: { acknowledgedIDs.append($0); events.append("ack"); return true },
                 didPrepare: { _, _ in events.append("complete") },
                 didWake: { events.append("wake") },
                 onFailure: { events.append("failure") })
        dispatch(InternalSystemPowerMessage.systemHasPoweredOn, notificationID: 48, active: false,
                 prepare: { events.append("prepare"); return true },
                 acknowledge: { acknowledgedIDs.append($0); events.append("ack"); return true },
                 didPrepare: { _, _ in events.append("complete") },
                 didWake: { events.append("wake") },
                 onFailure: { events.append("failure") })

        XCTAssertEqual(events, ["ack", "ack"])
        XCTAssertEqual(acknowledgedIDs, [46, 47])
    }

    private func dispatch(
        _ messageType: UInt32,
        notificationID: Int,
        active: Bool = true,
        prepare: () -> Bool,
        acknowledge: (Int) -> Bool,
        didPrepare: (Bool, Bool) -> Void,
        didWake: () -> Void,
        onFailure: () -> Void
    ) {
        InternalSystemPowerObserver.dispatchMessage(
            messageType,
            notificationID: notificationID,
            active: active,
            prepareForSleep: prepare,
            acknowledge: acknowledge,
            didPrepareForSleep: didPrepare,
            didWake: didWake,
            onFailure: onFailure
        )
    }
}
