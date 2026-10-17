import Darwin
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class SnapshotWitnessTests: XCTestCase {
    private struct Request: Encodable {
        let identity: UUID
        let numericIDHint: UInt32
    }

    private let identity = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!

    private func state(active: Bool) -> InternalDisplayState {
        InternalDisplayState(id: 7, identityUUID: identity, isBuiltIn: true, isOnline: active, isActive: active)
    }

    private func descriptor(_ peer: GuardChannel) throws -> Int32 {
        let copied = dup(peer.descriptor)
        guard copied >= 0 else { throw GuardChannelError.systemCall(errno) }
        return copied
    }

    func testOfflineInternalStateSurvivesRealSocketRoundTripAndDoubleRead() throws {
        let (client, server) = try GuardChannel.pair()
        try client.send(Request(identity: identity, numericIDHint: 7))
        let expected = state(active: false)
        var reads = 0
        try serveInternalDisplay(descriptor: descriptor(server)) { identity, hint, _ in
            XCTAssertEqual(identity, self.identity)
            XCTAssertEqual(hint, 7)
            reads += 1
            return expected
        }
        XCTAssertEqual(reads, 2)
        let received = try client.receive(InternalDisplayState.self)
        XCTAssertEqual(received, expected)
        XCTAssertFalse(received.isEnabled)
        XCTAssertTrue(received.matches(identity: identity))
    }

    func testChangedStateIsRejectedBeforeReply() throws {
        let (client, server) = try GuardChannel.pair()
        try client.send(Request(identity: identity, numericIDHint: 7))
        var reads = 0
        XCTAssertThrowsError(try serveInternalDisplay(descriptor: descriptor(server)) { _, _, _ in
            reads += 1
            return self.state(active: reads == 1)
        }) { error in
            XCTAssertEqual(snapshotWitnessFailureCode(error), "internal-state-changed")
        }
        XCTAssertEqual(reads, 2)
        var pending = pollfd(fd: client.descriptor, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pending, 1, 0), 0)
    }

    func testIdentityConflictPropagatesWithoutSecondReadOrFallback() throws {
        let (client, server) = try GuardChannel.pair()
        try client.send(Request(identity: identity, numericIDHint: 7))
        var reads = 0
        XCTAssertThrowsError(try serveInternalDisplay(descriptor: descriptor(server)) { _, _, _ in
            reads += 1
            throw RecoveryError.identityConflict
        }) { error in
            XCTAssertEqual(snapshotWitnessFailureCode(error), "identity-conflict")
        }
        XCTAssertEqual(reads, 1)
    }

    func testZeroHintIsRejectedWithoutReaderOrChild() throws {
        let (client, server) = try GuardChannel.pair()
        try client.send(Request(identity: identity, numericIDHint: 0))
        var reads = 0
        XCTAssertThrowsError(try serveInternalDisplay(descriptor: descriptor(server)) { _, _, _ in
            reads += 1
            return self.state(active: false)
        }) { error in
            XCTAssertEqual(snapshotWitnessFailureCode(error), "witness-invalid-state")
        }
        XCTAssertEqual(reads, 0)
        XCTAssertThrowsError(try freshInternalDisplay(identity: identity, numericIDHint: 0))
    }

    func testDiagnosticsDistinguishFailuresWithoutRenderingUnderlyingError() {
        struct PrivateError: Error, CustomStringConvertible { var description: String { "private-device-data" } }
        XCTAssertEqual(snapshotWitnessFailureCode(PrivateError()), "unclassified")
        XCTAssertEqual(snapshotWitnessFailureCode(GuardChannelError.peerClosed), "channel-closed")
        XCTAssertEqual(snapshotWitnessFailureCode(GuardChannelError.timedOut), "channel-timeout")
        XCTAssertEqual(snapshotWitnessFailureCode(SnapshotWitnessError.processFailed), "witness-exit")
        XCTAssertEqual(snapshotWitnessFailureCode(SnapshotWitnessError.spawnFailed), "witness-spawn")
        XCTAssertEqual(snapshotWitnessFailureCode(SnapshotWitnessError.cleanupFailed), "witness-cleanup")
    }
}
