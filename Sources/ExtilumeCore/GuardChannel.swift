import Darwin
import Foundation

public enum GuardChannelError: Error, Equatable {
    case invalidDescriptor
    case systemCall(Int32)
    case timedOut
    case peerClosed
    case truncatedMessage
    case invalidLength
    case invalidMessage
    case messageTooLarge
}

public final class GuardChannel: @unchecked Sendable {
    private static let maximumMessageSize = 4_096

    public let descriptor: Int32
    private let timeoutNanoseconds: UInt64
    private let sendLock = NSLock()
    private let receiveLock = NSLock()

    public init(descriptor: Int32, timeoutNanoseconds: UInt64 = 2_000_000_000) throws {
        guard descriptor >= 0 else { throw GuardChannelError.invalidDescriptor }
        try Self.configure(descriptor)
        self.descriptor = descriptor
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    deinit {
        Darwin.close(descriptor)
    }

    public static func pair() throws -> (GuardChannel, GuardChannel) {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw GuardChannelError.systemCall(errno)
        }

        var leftOwned = true
        var rightOwned = true
        do {
            let left = try GuardChannel(descriptor: descriptors[0])
            leftOwned = false
            let right = try GuardChannel(descriptor: descriptors[1])
            rightOwned = false
            return (left, right)
        } catch {
            if leftOwned { Darwin.close(descriptors[0]) }
            if rightOwned { Darwin.close(descriptors[1]) }
            throw error
        }
    }

    public func send<T: Encodable>(
        _ value: T,
        deadlineNanoseconds: UInt64? = nil,
        checkAccess: (() throws -> Void)? = nil
    ) throws {
        let deadline: UInt64
        if let deadlineNanoseconds {
            deadline = deadlineNanoseconds
        } else {
            deadline = try makeDeadline()
        }
        guard try ContinuousClock.nanoseconds() < deadline else { throw GuardChannelError.timedOut }
        let payload: Data
        do { payload = try JSONEncoder().encode(value) }
        catch { throw GuardChannelError.invalidMessage }
        guard !payload.isEmpty, payload.count <= Self.maximumMessageSize else {
            throw GuardChannelError.messageTooLarge
        }

        sendLock.lock()
        defer { sendLock.unlock() }

        var bigEndianLength = UInt32(payload.count).bigEndian
        let header = withUnsafeBytes(of: &bigEndianLength) { Data($0) }
        try writeAll(header, deadline: deadline, checkAccess: checkAccess)
        try writeAll(payload, deadline: deadline, checkAccess: checkAccess)
    }

    public func receive<T: Decodable>(
        _ type: T.Type,
        deadlineNanoseconds: UInt64? = nil,
        checkAccess: (() throws -> Void)? = nil
    ) throws -> T {
        let deadline: UInt64
        if let deadlineNanoseconds {
            deadline = deadlineNanoseconds
        } else {
            deadline = try makeDeadline()
        }
        guard try ContinuousClock.nanoseconds() < deadline else { throw GuardChannelError.timedOut }
        receiveLock.lock()
        defer { receiveLock.unlock() }

        var header = Data(count: 4)
        try header.withUnsafeMutableBytes { try readExactly($0, deadline: deadline, checkAccess: checkAccess) }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= Self.maximumMessageSize else { throw GuardChannelError.invalidLength }

        var payload = Data(count: Int(length))
        try payload.withUnsafeMutableBytes { try readExactly($0, deadline: deadline, checkAccess: checkAccess, frameStarted: true) }
        do { return try JSONDecoder().decode(type, from: payload) }
        catch { throw GuardChannelError.invalidMessage }
    }

    public func peerClosed() throws -> Bool {
        var byte: UInt8 = 0
        while true {
            var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if poll(&state, 1, 0) == -1 {
                if errno == EINTR { continue }
                throw GuardChannelError.systemCall(errno)
            }
            if state.revents & Int16(POLLNVAL) != 0 { throw GuardChannelError.invalidDescriptor }
            if state.revents & Int16(POLLHUP | POLLERR) != 0 { return true }
            let count = Darwin.recv(descriptor, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
            if count == 0 { return true }
            if count > 0 { return false }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return false }
            throw GuardChannelError.systemCall(errno)
        }
    }

    private static func configure(_ descriptor: Int32) throws {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags != -1 else { throw GuardChannelError.systemCall(errno) }
        guard fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) != -1 else {
            throw GuardChannelError.systemCall(errno)
        }

        let statusFlags = fcntl(descriptor, F_GETFL)
        guard statusFlags != -1 else { throw GuardChannelError.systemCall(errno) }
        guard fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) != -1 else {
            throw GuardChannelError.systemCall(errno)
        }

        var noSignal: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSignal,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else { throw GuardChannelError.systemCall(errno) }
    }

    private func makeDeadline() throws -> UInt64 {
        let now = try ContinuousClock.nanoseconds()
        let (deadline, overflow) = now.addingReportingOverflow(timeoutNanoseconds)
        return overflow ? UInt64.max : deadline
    }

    private func wait(
        for events: Int16,
        until deadline: UInt64,
        checkAccess: (() throws -> Void)?
    ) throws {
        while true {
            var now = try ContinuousClock.nanoseconds()
            guard now < deadline else { throw GuardChannelError.timedOut }
            var maximumPollMilliseconds = UInt64(Int32.max)
            if let checkAccess {
                try checkAccess()
                now = try ContinuousClock.nanoseconds()
                guard now < deadline else { throw GuardChannelError.timedOut }
                maximumPollMilliseconds = 50
            }
            let remaining = deadline - now
            let milliseconds = remaining / 1_000_000 + (remaining % 1_000_000 == 0 ? 0 : 1)
            let timeout = Int32(min(milliseconds, maximumPollMilliseconds))
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, timeout)
            if result == -1 {
                if errno == EINTR { continue }
                throw GuardChannelError.systemCall(errno)
            }
            if result == 0 { continue }
            if pollDescriptor.revents & Int16(POLLNVAL) != 0 { throw GuardChannelError.invalidDescriptor }
            if pollDescriptor.revents & (events | Int16(POLLERR) | Int16(POLLHUP)) != 0 {
                guard try ContinuousClock.nanoseconds() < deadline else { throw GuardChannelError.timedOut }
                if let checkAccess {
                    try checkAccess()
                    guard try ContinuousClock.nanoseconds() < deadline else { throw GuardChannelError.timedOut }
                }
                return
            }
        }
    }

    private func writeAll(_ data: Data, deadline: UInt64, checkAccess: (() throws -> Void)?) throws {
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                try wait(for: Int16(POLLOUT), until: deadline, checkAccess: checkAccess)
                guard try ContinuousClock.nanoseconds() < deadline else { throw GuardChannelError.timedOut }
                let count = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    buffer.count - offset,
                    0
                )
                if count > 0 {
                    offset += count
                } else if count == -1 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK) {
                    continue
                } else if count == 0 {
                    throw GuardChannelError.peerClosed
                } else {
                    throw GuardChannelError.systemCall(errno)
                }
            }
        }
    }

    private func readExactly(
        _ buffer: UnsafeMutableRawBufferPointer,
        deadline: UInt64,
        checkAccess: (() throws -> Void)?,
        frameStarted: Bool = false
    ) throws {
        guard let baseAddress = buffer.baseAddress else { return }
        var offset = 0
        while offset < buffer.count {
            try wait(for: Int16(POLLIN), until: deadline, checkAccess: checkAccess)
            guard try ContinuousClock.nanoseconds() < deadline else { throw GuardChannelError.timedOut }
            let count = Darwin.recv(
                descriptor,
                baseAddress.advanced(by: offset),
                buffer.count - offset,
                0
            )
            if count > 0 {
                offset += count
            } else if count == 0 {
                throw frameStarted || offset > 0 ? GuardChannelError.truncatedMessage : GuardChannelError.peerClosed
            } else if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                continue
            } else {
                throw GuardChannelError.systemCall(errno)
            }
        }
    }
}
