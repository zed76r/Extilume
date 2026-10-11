import Darwin
import Foundation
import XCTest
@testable import ExtilumeCore

final class GuardChannelTests: XCTestCase {
    private struct Message: Codable, Equatable {
        let sequence: Int
        let text: String
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
