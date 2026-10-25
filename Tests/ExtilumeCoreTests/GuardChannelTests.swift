import Darwin
import Foundation
import XCTest
@testable import ExtilumeCore

final class GuardChannelTests: XCTestCase {
    private struct Message: Codable, Equatable, Sendable {
        let sequence: Int
        let text: String
    }

    private enum AccessError: Error, Equatable {
        case cancelled
    }

    func testPairCarriesMessagesInBothDirectionsAndHasRequiredSocketFlags() throws {
        let (left, right) = try GuardChannel.pair()
        let outbound = Message(sequence: 1, text: "left to right")
        let reply = Message(sequence: 2, text: "right to left")

        for channel in [left, right] {
            let descriptorFlags = fcntl(channel.descriptor, F_GETFD)
            let statusFlags = fcntl(channel.descriptor, F_GETFL)
            XCTAssertNotEqual(descriptorFlags & FD_CLOEXEC, 0)
            XCTAssertNotEqual(statusFlags & O_NONBLOCK, 0)
            var noSignal: Int32 = 0
            var optionLength = socklen_t(MemoryLayout<Int32>.size)
            XCTAssertEqual(
                getsockopt(channel.descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, &optionLength),
                0
            )
            XCTAssertEqual(noSignal, 1)
        }

        try left.send(outbound)
        XCTAssertFalse(try right.peerClosed())
        XCTAssertEqual(try right.receive(Message.self), outbound)
        try right.send(reply)
        XCTAssertEqual(try left.receive(Message.self), reply)
    }

    func testMaximumPayloadIsAcceptedAndLargerPayloadRejected() throws {
        let (left, right) = try makePair(timeoutNanoseconds: 100_000_000)
        let maximum = String(repeating: "x", count: 4_094)
        try left.send(maximum)
        XCTAssertEqual(try right.receive(String.self), maximum)

        let oversized = String(repeating: "x", count: 4_095)
        XCTAssertThrowsError(try left.send(oversized)) { error in
            XCTAssertEqual(error as? GuardChannelError, .messageTooLarge)
        }
    }

    func testReceiveTimesOutWhenNoMessageArrives() throws {
        let (left, right) = try makePair(timeoutNanoseconds: 50_000_000)

        try withExtendedLifetime(right) {
            XCTAssertThrowsError(try left.receive(Message.self)) { error in
                XCTAssertEqual(error as? GuardChannelError, .timedOut)
            }
        }
    }

    func testReceiveUsesAbsoluteDeadlineBeyondShortDefaultTimeout() throws {
        let (receiver, sender) = try makePair(timeoutNanoseconds: 25_000_000)
        let message = Message(sequence: 3, text: "late reply")
        let deadline = try ContinuousClock.nanoseconds() + 180_000_000

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(60)) {
            try? sender.send(message)
        }

        XCTAssertEqual(
            try receiver.receive(Message.self, deadlineNanoseconds: deadline),
            message
        )
    }

    func testExpiredDeadlineDoesNotConsumeBufferedMessage() throws {
        let (receiver, sender) = try makePair(timeoutNanoseconds: 100_000_000)
        let message = Message(sequence: 4, text: "buffered")
        try sender.send(message)

        let expiredDeadline = try ContinuousClock.nanoseconds() - 1
        XCTAssertThrowsError(
            try receiver.receive(Message.self, deadlineNanoseconds: expiredDeadline)
        ) { error in
            XCTAssertEqual(error as? GuardChannelError, .timedOut)
        }
        XCTAssertEqual(try receiver.receive(Message.self), message)
    }

    func testReceiveTimesOutAtAbsoluteDeadlineWhenNoMessageArrives() throws {
        let (receiver, peer) = try makePair(timeoutNanoseconds: 200_000_000)
        let startedAt = try ContinuousClock.nanoseconds()
        let deadline = startedAt + 50_000_000

        try withExtendedLifetime(peer) {
            XCTAssertThrowsError(
                try receiver.receive(Message.self, deadlineNanoseconds: deadline)
            ) { error in
                XCTAssertEqual(error as? GuardChannelError, .timedOut)
            }
        }

        XCTAssertLessThan(try ContinuousClock.nanoseconds() - startedAt, 150_000_000)
    }

    func testReceivePropagatesAccessCancellationWithinOneBoundedPoll() throws {
        let (receiver, peer) = try makePair(timeoutNanoseconds: 200_000_000)
        let startedAt = try ContinuousClock.nanoseconds()
        var accessChecks = 0

        try withExtendedLifetime(peer) {
            XCTAssertThrowsError(try receiver.receive(Message.self, checkAccess: {
                accessChecks += 1
                if accessChecks == 2 { throw AccessError.cancelled }
            })) { error in
                XCTAssertEqual(error as? AccessError, .cancelled)
            }
        }

        XCTAssertEqual(accessChecks, 2)
        XCTAssertLessThan(try ContinuousClock.nanoseconds() - startedAt, 150_000_000)
    }

    func testSendPropagatesReadyAccessCancellationWithoutWritingBytes() throws {
        let (sender, peer) = try makePair(timeoutNanoseconds: 100_000_000)
        var accessChecks = 0

        XCTAssertThrowsError(try sender.send(Message(sequence: 5, text: "cancelled"), checkAccess: {
            accessChecks += 1
            if accessChecks == 2 { throw AccessError.cancelled }
        })) { error in
            XCTAssertEqual(error as? AccessError, .cancelled)
        }

        XCTAssertEqual(accessChecks, 2)
        var byte: UInt8 = 0
        XCTAssertEqual(Darwin.recv(peer.descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT), -1)
        XCTAssertTrue(errno == EAGAIN || errno == EWOULDBLOCK)
    }

    func testPeerEOFIsReportedWithoutConsumingData() throws {
        let (channel, peerDescriptor) = try makeChannel(timeoutNanoseconds: 100_000_000)
        var peerOpen = true
        defer { if peerOpen { Darwin.close(peerDescriptor) } }

        XCTAssertFalse(try channel.peerClosed())
        Darwin.close(peerDescriptor)
        peerOpen = false
        XCTAssertTrue(try channel.peerClosed())
        XCTAssertThrowsError(try channel.receive(Message.self)) { error in
            XCTAssertEqual(error as? GuardChannelError, .peerClosed)
        }
    }

    func testPartialFrameEOFIsNotAnOrderlyEndOfStream() throws {
        for bytes: [UInt8] in [[0x00], [0x00, 0x00, 0x00, 0x04], [0x00, 0x00, 0x00, 0x04, 0x7b]] {
            let (channel, peer) = try makeChannel(timeoutNanoseconds: 100_000_000)
            try write(bytes, to: peer)
            Darwin.close(peer)
            XCTAssertThrowsError(try channel.receive(Message.self)) { error in
                XCTAssertEqual(error as? GuardChannelError, .truncatedMessage)
            }
        }
    }

    func testClosedPeerIsDetectedEvenWithBufferedControlBytes() throws {
        let (channel, peer) = try makeChannel(timeoutNanoseconds: 100_000_000)
        try write([0x00, 0x00, 0x00, 0x04, 0x7b], to: peer)
        Darwin.close(peer)
        XCTAssertTrue(try channel.peerClosed())
    }

    func testRejectsOutOfRangeFrameLengthAndMalformedJSON() throws {
        do {
            let (receiver, peer) = try makePair(timeoutNanoseconds: 100_000_000)
            try write([0x00, 0x00, 0x10, 0x01], to: peer.descriptor)
            XCTAssertThrowsError(try receiver.receive(Message.self)) { error in
                XCTAssertEqual(error as? GuardChannelError, .invalidLength)
            }
        }

        do {
            let (receiver, peer) = try makePair(timeoutNanoseconds: 100_000_000)
            try write([0x00, 0x00, 0x00, 0x01, 0x7B], to: peer.descriptor)
            XCTAssertThrowsError(try receiver.receive(Message.self)) { error in
                XCTAssertEqual(error as? GuardChannelError, .invalidMessage)
            }
        }
    }

    private func makePair(timeoutNanoseconds: UInt64) throws -> (GuardChannel, GuardChannel) {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw GuardChannelError.systemCall(errno)
        }
        var leftOwned = true
        var rightOwned = true
        do {
            let left = try GuardChannel(descriptor: descriptors[0], timeoutNanoseconds: timeoutNanoseconds)
            leftOwned = false
            let right = try GuardChannel(descriptor: descriptors[1], timeoutNanoseconds: timeoutNanoseconds)
            rightOwned = false
            return (left, right)
        } catch {
            if leftOwned { Darwin.close(descriptors[0]) }
            if rightOwned { Darwin.close(descriptors[1]) }
            throw error
        }
    }

    private func makeChannel(timeoutNanoseconds: UInt64) throws -> (GuardChannel, Int32) {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw GuardChannelError.systemCall(errno)
        }
        do {
            return (try GuardChannel(descriptor: descriptors[0], timeoutNanoseconds: timeoutNanoseconds), descriptors[1])
        } catch {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw error
        }
    }

    private func write(_ bytes: [UInt8], to descriptor: Int32) throws {
        let count = bytes.withUnsafeBytes { buffer in
            Darwin.send(descriptor, buffer.baseAddress!, buffer.count, 0)
        }
        guard count == bytes.count else { throw GuardChannelError.systemCall(errno) }
    }
}
