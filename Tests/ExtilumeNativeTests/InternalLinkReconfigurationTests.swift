import XCTest
@testable import ExtilumeNative

final class InternalLinkReconfigurationTests: XCTestCase {
    private let candidates: [UInt64: ExternalConnectionService] = [
        101: .device, 202: .service, 303: .videoInterface,
    ]
    private let video: [UInt32] = [0xe0115004, 0xe0115005, 0xe0115000, 0xe0115001]

    private func collecting(at time: UInt64 = 100) -> InternalLinkReconfiguration {
        var state = InternalLinkReconfiguration()
        XCTAssertTrue(state.prepare(candidates: candidates))
        XCTAssertTrue(state.begin(at: time))
        return state
    }

    @discardableResult
    private func send(
        _ state: inout InternalLinkReconfiguration, _ id: UInt64, _ code: UInt32,
        _ argument: ConnectionObservedArgument = .one, at time: UInt64
    ) -> Bool {
        state.consume(entryID: id, messageType: code, argument: argument, at: time)
    }

    private func cycle(_ state: inout InternalLinkReconfiguration, _ id: UInt64, from time: UInt64) {
        for (offset, code) in video.enumerated() {
            XCTAssertTrue(send(&state, id, code, at: time + UInt64(offset)))
        }
    }

    func testThreeVideoCyclesAndAudioPrefixRemainPendingUntilReadback() {
        var state = collecting()
        cycle(&state, 101, from: 101)
        for (offset, code) in video.prefix(3).enumerated() {
            XCTAssertTrue(send(&state, 101, code, .zero, at: 105 + UInt64(offset)))
        }
        cycle(&state, 202, from: 108)
        cycle(&state, 303, from: 112)
        XCTAssertTrue(state.isPending)
        XCTAssertEqual(state.firstPendingAt, 101)
        XCTAssertTrue(state.endNative(succeeded: true, at: 116))
        XCTAssertTrue(state.isPending)
        XCTAssertTrue(state.verify(at: 117))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.firstPendingAt)
        XCTAssertFalse(state.isPending)
    }

    func testNormalizedFirstHardwareRoundReplaysOnlyInsideItsNativeWindow() {
        // 2026-10-19: relative times and synthetic class ordinals only; this is not device acceptance.
        let base: UInt64 = 1_000_000_000
        var state = InternalLinkReconfiguration()
        XCTAssertTrue(state.prepare(candidates: [1: .device, 2: .service, 3: .videoInterface]))
        XCTAssertTrue(state.begin(at: base - 70_806_292))
        let events: [(UInt64, UInt32, ConnectionObservedArgument, UInt64)] = [
            (1, 0xe0115004, .one, 0),
            (2, 0xe0115004, .one, 70_375),
            (3, 0xe0115004, .one, 136_625),
            (1, 0xe0115005, .one, 3_174_333),
            (2, 0xe0115005, .one, 3_234_458),
            (3, 0xe0115005, .one, 3_318_833),
            (1, 0xe0115004, .zero, 5_450_333),
            (2, 0xe0115004, .zero, 5_532_042),
            (3, 0xe0115004, .zero, 5_635_708),
            (1, 0xe0115005, .zero, 6_920_333),
            (2, 0xe0115005, .zero, 6_990_750),
            (3, 0xe0115005, .zero, 7_106_667),
            (1, 0xe0115000, .one, 215_256_417),
            (2, 0xe0115000, .one, 215_358_667),
            (3, 0xe0115000, .one, 215_494_833),
            (1, 0xe0115000, .zero, 227_153_000),
            (2, 0xe0115000, .zero, 227_208_833),
            (3, 0xe0115000, .zero, 227_298_583),
            (1, 0xe0115001, .one, 239_096_958),
            (2, 0xe0115001, .one, 239_165_708),
            (3, 0xe0115001, .one, 239_229_042),
        ]
        for (id, code, argument, relative) in events {
            XCTAssertTrue(state.consume(entryID: id, messageType: code, argument: argument, at: base + relative))
        }
        XCTAssertEqual(state.firstPendingAt, base)
        XCTAssertTrue(state.endNative(succeeded: true, at: base + 361_536_000))
        XCTAssertTrue(state.isPending)
        XCTAssertTrue(state.verify(at: base + 400_000_000))
    }

    func testNativeSuccessWithoutMediaCanVerify() {
        var state = collecting()
        XCTAssertFalse(state.isPending)
        XCTAssertTrue(state.endNative(succeeded: true, at: 101))
        XCTAssertTrue(state.verify(at: 102))
        XCTAssertEqual(state.phase, .idle)
    }

    func testIncompleteDuplicateOutOfOrderAndSecondCycleFailClosed() {
        var missing = collecting()
        for id: UInt64 in [101, 202, 303] {
            for code in video.dropLast() { XCTAssertTrue(send(&missing, id, code, at: UInt64(video.firstIndex(of: code)!) + id)) }
        }
        XCTAssertFalse(missing.endNative(succeeded: true, at: 400))
        XCTAssertEqual(missing.phase, .failed)

        var duplicate = collecting()
        XCTAssertTrue(send(&duplicate, 101, video[0], at: 101))
        XCTAssertFalse(send(&duplicate, 101, video[0], at: 102))
        XCTAssertEqual(duplicate.firstPendingAt, 101)

        var outOfOrder = collecting()
        XCTAssertFalse(send(&outOfOrder, 101, video[2], at: 101))
        XCTAssertEqual(outOfOrder.phase, .failed)

        var second = collecting()
        cycle(&second, 101, from: 101)
        XCTAssertFalse(send(&second, 101, video[0], at: 105))
    }

    func testUnknownCodeAndUnsupportedArgumentsFail() {
        for (code, argument) in [(UInt32(0xe0115002), ConnectionObservedArgument.one),
                                 (0xe0115004, .two), (0xe0115004, .other)] {
            var state = collecting()
            XCTAssertFalse(send(&state, 101, code, argument, at: 101))
            XCTAssertEqual(state.phase, .failed)
        }
    }

    func testCandidateSetMustBeExactlyThreeUniqueNonzeroExternalEntries() {
        var zero = InternalLinkReconfiguration()
        XCTAssertFalse(zero.prepare(candidates: [0: .device, 202: .service, 303: .videoInterface]))
        XCTAssertEqual(zero.phase, .failed)

        var duplicateClass = InternalLinkReconfiguration()
        XCTAssertFalse(duplicateClass.prepare(candidates: [101: .device, 202: .device, 303: .videoInterface]))

        var missing = InternalLinkReconfiguration()
        XCTAssertFalse(missing.prepare(candidates: [101: .device, 202: .service]))

        var outside = collecting()
        XCTAssertFalse(send(&outside, 404, video[0], at: 101))
        XCTAssertEqual(outside.phase, .failed)
    }

    func testFailedStateRetainsFirstDeadlineAndCannotRestartOrVerify() {
        var state = collecting()
        XCTAssertTrue(send(&state, 101, video[0], at: 101))
        XCTAssertEqual(state.fail(), 101)
        XCTAssertEqual(state.fail(), 101)
        XCTAssertFalse(state.verify(at: 102))
        XCTAssertFalse(state.prepare(candidates: candidates))
        XCTAssertEqual(state.phase, .failed)
        XCTAssertEqual(state.firstPendingAt, 101)
    }

    func testTimeMustNotMoveBackwardAndNativeReturnFollowsObservedCallbacks() {
        var beforeBegin = collecting()
        XCTAssertFalse(send(&beforeBegin, 101, video[0], at: 99))

        var backwards = collecting()
        XCTAssertTrue(send(&backwards, 101, video[0], at: 101))
        XCTAssertFalse(send(&backwards, 101, video[1], at: 100))

        var lateCallback = collecting()
        XCTAssertTrue(send(&lateCallback, 101, video[0], at: 101))
        XCTAssertFalse(lateCallback.endNative(succeeded: true, at: 100))
        XCTAssertEqual(lateCallback.phase, .failed)
    }

    func testVideoTimeMustIncreasePerEntryButDifferentEntriesMayShareTimestamp() {
        var sameEntry = collecting()
        XCTAssertTrue(send(&sameEntry, 101, video[0], at: 101))
        XCTAssertFalse(send(&sameEntry, 101, video[1], at: 101))
        XCTAssertEqual(sameEntry.phase, .failed)

        var differentEntries = collecting()
        XCTAssertTrue(send(&differentEntries, 101, video[0], at: 101))
        XCTAssertTrue(send(&differentEntries, 202, video[0], at: 101))
        XCTAssertEqual(differentEntries.phase, .collecting)
    }

    func testNativeFailureAndTenSecondPendingWindowAreNotRenewed() {
        var nativeFailure = collecting()
        cycle(&nativeFailure, 101, from: 101)
        cycle(&nativeFailure, 202, from: 105)
        cycle(&nativeFailure, 303, from: 109)
        XCTAssertFalse(nativeFailure.endNative(succeeded: false, at: 114))
        XCTAssertEqual(nativeFailure.firstPendingAt, 101)

        var timeout = collecting()
        XCTAssertTrue(send(&timeout, 101, video[0], at: 101))
        XCTAssertFalse(send(&timeout, 101, video[1], at: 10_000_000_101))
        XCTAssertEqual(timeout.phase, .failed)
        XCTAssertEqual(timeout.firstPendingAt, 101)

        var waitTimeout = collecting()
        XCTAssertTrue(send(&waitTimeout, 101, video[0], at: 101))
        XCTAssertFalse(waitTimeout.endNative(succeeded: true, at: 10_000_000_101))
    }

    func testConsumeCannotEnterAfterNativeReturnOrAfterVerification() {
        var afterReturn = collecting()
        XCTAssertTrue(afterReturn.endNative(succeeded: true, at: 101))
        XCTAssertFalse(send(&afterReturn, 101, video[0], at: 102))
        XCTAssertEqual(afterReturn.phase, .failed)

        var afterVerify = collecting()
        XCTAssertTrue(afterVerify.endNative(succeeded: true, at: 101))
        XCTAssertTrue(afterVerify.verify(at: 102))
        XCTAssertFalse(send(&afterVerify, 101, video[0], at: 103))
        XCTAssertEqual(afterVerify.phase, .failed)
    }
}
