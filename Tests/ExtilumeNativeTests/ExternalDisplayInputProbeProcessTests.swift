import Darwin
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class ExternalDisplayInputProbeProcessTests: XCTestCase {
    func testChildRequestsAndReceivesExactApproval() throws {
        let request = try makeRequest()
        let state = ExternalDisplayState(id: 42, identity: request.target, isOnline: true, isActive: false)
        var child: pid_t = 0
        var approvals = 0
        let reply = try runExternalDisplayInputProbe(request, checkAccess: {}, authorizeWrite: {
            approvals += 1
            return state
        }, spawn: { _, channel in
            child = try self.spawnFixture(channel: channel, mode: "success")
            return child
        })
        XCTAssertEqual(reply, .confirmed(target: request.target, input: 0x11))
        XCTAssertEqual(approvals, 1)
        try assertReaped(child)
    }

    func testCancellationWhileChildReadsCapabilitiesPreventsApprovalAndReapsChild() throws {
        let request = try makeRequest()
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw SnapshotWitnessError.spawnFailed }
        defer { close(descriptors[0]); close(descriptors[1]) }
        let flags = fcntl(descriptors[0], F_GETFL)
        guard flags != -1, fcntl(descriptors[0], F_SETFL, flags | O_NONBLOCK) != -1 else {
            throw SnapshotWitnessError.spawnFailed
        }
        var child: pid_t = 0
        var cancelled = false
        var approvals = 0
        XCTAssertThrowsError(try runExternalDisplayInputProbe(request, checkAccess: {
            var marker: UInt8 = 0
            if read(descriptors[0], &marker, 1) == 1 { cancelled = true }
            if cancelled { throw ExternalDisplayInputFailure.hardwareAcceptanceRequired }
        }, authorizeWrite: {
            approvals += 1
            return ExternalDisplayState(id: 42, identity: request.target, isOnline: true, isActive: false)
        }, spawn: { _, channel in
            child = try self.spawnFixture(channel: channel, mode: "cancel", marker: descriptors[1])
            return child
        }))
        XCTAssertTrue(cancelled)
        XCTAssertEqual(approvals, 0)
        try assertReaped(child)
    }

    func testWrongReadyAndFailedExitNeverApprove() throws {
        for mode in ["target", "input", "deadline", "exit"] {
            let request = try makeRequest()
            var child: pid_t = 0
            var approvals = 0
            XCTAssertThrowsError(try runExternalDisplayInputProbe(request, authorizeWrite: {
                approvals += 1
                return ExternalDisplayState(id: 42, identity: request.target, isOnline: true, isActive: false)
            }, spawn: { _, channel in
                child = try self.spawnFixture(channel: channel, mode: mode)
                return child
            }), "mode: \(mode)")
            XCTAssertEqual(approvals, 0, "mode: \(mode)")
            try assertReaped(child)
        }
    }

    private func makeRequest() throws -> ExternalDisplayInputProbeRequest {
        let target = ExternalDisplayIdentity(uuid: UUID(), registryPath: "IOService:/display/1",
            edidUUID: "test-edid", bootSession: UUID(), registryEntryID: 42)
        return ExternalDisplayInputProbeRequest(target: target, operation: .selectInput(0x11),
            deadlineNanoseconds: try ContinuousClock.nanoseconds() + 2_000_000_000)
    }

    private func assertReaped(_ child: pid_t, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertGreaterThan(child, 1, file: file, line: line)
        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(child, &status, WNOHANG), -1, file: file, line: line)
        XCTAssertEqual(errno, ECHILD, file: file, line: line)
    }

    private func spawnFixture(channel: GuardChannel, mode: String, marker: Int32? = nil) throws -> pid_t {
        let script = #"""
import json, os, socket, struct, sys, time
s = socket.socket(fileno=198)
s.setblocking(True)
def recv(n):
    data = b''
    while len(data) < n:
        part = s.recv(n - len(data))
        if not part: raise EOFError()
        data += part
    return data
def receive():
    return json.loads(recv(struct.unpack('>I', recv(4))[0]))
def send(value):
    data = json.dumps(value, separators=(',', ':')).encode()
    s.sendall(struct.pack('>I', len(data)) + data)
r = receive()
mode = sys.argv[1]
if mode == 'exit': sys.exit(7)
if mode == 'cancel':
    os.write(199, b'x')
    time.sleep(0.5)
ready = {'target': r['target'], 'input': r['operation']['selectInput']['_0'], 'deadlineNanoseconds': r['deadlineNanoseconds']}
if mode == 'target': ready['target'] = dict(ready['target'], registryEntryID=999)
if mode == 'input': ready['input'] += 1
if mode == 'deadline': ready['deadlineNanoseconds'] += 1
send(ready)
approved = receive()
if approved['identity'] != r['target'] or approved['isActive'] or approved['id'] != 42: sys.exit(8)
send({'confirmed': {'target': r['target'], 'input': ready['input']}})
"""#
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SnapshotWitnessError.spawnFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addinherit_np(&actions, descriptor) == 0 else { throw SnapshotWitnessError.spawnFailed }
        }
        guard posix_spawn_file_actions_adddup2(&actions, channel.descriptor, 198) == 0 else { throw SnapshotWitnessError.spawnFailed }
        if let marker {
            guard posix_spawn_file_actions_adddup2(&actions, marker, 199) == 0 else { throw SnapshotWitnessError.spawnFailed }
        }
        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw SnapshotWitnessError.spawnFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)) == 0 else {
            throw SnapshotWitnessError.spawnFailed
        }
        let strings = ["/usr/bin/python3", "-c", script, mode].map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var arguments: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
        var child: pid_t = 0
        let result = arguments.withUnsafeMutableBufferPointer {
            posix_spawn(&child, "/usr/bin/python3", &actions, &attributes, $0.baseAddress!, environ)
        }
        guard result == 0, child > 1 else { throw SnapshotWitnessError.spawnFailed }
        return child
    }
}
