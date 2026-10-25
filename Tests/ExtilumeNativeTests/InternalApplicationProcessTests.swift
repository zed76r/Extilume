import Darwin
import Foundation
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

@MainActor
final class InternalApplicationProcessTests: XCTestCase {
    private final class Results: @unchecked Sendable {
        let lock = NSLock()
        var values: [PrimarySessionStatus] = []
        var result: Bool?
        func append(_ value: PrimarySessionStatus) { lock.withLock { values.append(value) } }
        func complete(_ value: Bool) { lock.withLock { result = value } }
        func has(_ value: PrimarySessionStatus) -> Bool { lock.withLock { values.contains(value) } }
        var completion: Bool? { lock.withLock { result } }
    }

    func testRealChildWaitingEOFDoesNotBecomeProtectionFailure() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = Results()
        let controller = try InternalApplicationController(directory: directory, processFactory: fixture("waiting"))
        controller.startApplication(registerEvents: false) { results.append($0) }
        XCTAssertTrue(pump { results.has(.waiting) })
        XCTAssertFalse(results.has(.recoveryIncomplete))
        controller.quitApplication { results.complete($0) }
        XCTAssertTrue(pump { results.completion != nil })
        XCTAssertEqual(results.completion, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("recovery-record.json").path))
    }

    func testRealChildQuitDuringLaunchCompletesAfterExitAndChannelDrain() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = Results()
        let controller = try InternalApplicationController(directory: directory, processFactory: fixture("recovery"))
        controller.startApplication(registerEvents: false) { results.append($0) }
        controller.quitApplication { results.complete($0) }
        XCTAssertTrue(pump { results.completion != nil })
        XCTAssertEqual(results.completion, true)
        XCTAssertFalse(results.has(.recoveryIncomplete))
    }

    func testRealChildFaultDuringQuitCannotBeOverwrittenByExitZero() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let results = Results()
        let controller = try InternalApplicationController(directory: directory, processFactory: fixture("fault-during-quit"))
        controller.startApplication(registerEvents: false) { results.append($0) }
        controller.quitApplication { results.complete($0) }
        XCTAssertTrue(pump { results.completion != nil })
        XCTAssertEqual(results.completion, false)
    }

    func testWrongUserHandshakeNeverReceivesStartAndUnreadyAppliedIsRejected() throws {
        for scenario in ["wrong-user", "unready-applied"] {
            let directory = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = directory.appendingPathComponent("start-received")
            let results = Results()
            let controller = try InternalApplicationController(directory: directory, processFactory: fixture(scenario, marker: marker.path))
            controller.startApplication(registerEvents: false) { results.append($0) }
            XCTAssertTrue(pump { results.has(.recoveryIncomplete) })
            XCTAssertFalse(results.has(.applied))
            if scenario == "wrong-user" { XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path)) }
            withExtendedLifetime(controller) {}
        }
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ExtilumeIPC-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func pump(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(5)
        while !condition() && Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
        return condition()
    }

    private func fixture(_ scenario: String, marker: String = "") -> InternalApplicationProcessFactory {
        let script = """
        import json, os, socket, struct, sys
        channel = socket.socket(fileno=198)
        channel.settimeout(3)
        def exact(n):
            data = b''
            while len(data) < n:
                piece = channel.recv(n-len(data))
                if not piece: raise EOFError()
                data += piece
            return data
        def receive():
            return json.loads(exact(struct.unpack('!I', exact(4))[0]))
        def send(value):
            payload = json.dumps(value).encode()
            channel.sendall(struct.pack('!I', len(payload)) + payload)
        try:
            request = receive()
            send({'ready': {'_0': {'challenge': request['challenge'], 'workerPID': os.getpid(),
                  'workerUID': os.getuid() + (1 if sys.argv[1] == 'wrong-user' else 0), 'version': 1}}})
            command = receive()
            if sys.argv[2]:
                with open(sys.argv[2], 'w') as marker: marker.write('start')
            if sys.argv[1] == 'waiting': send({'status': {'_0': {'waiting': {}}}})
            elif sys.argv[1] == 'fault-during-quit': send({'faulted': {}})
            elif sys.argv[1] == 'recovery':
                assert command == {'start': {'recoveryOnly': True}}
                send({'status': {'_0': {'applicationFailedRestored': {}}}})
            elif sys.argv[1] == 'unready-applied': send({'status': {'_0': {'applied': {}}}})
            send({'finished': {}})
        except (EOFError, BrokenPipeError): pass
        """
        return { _, channel in
            var actions: posix_spawn_file_actions_t?
            guard posix_spawn_file_actions_init(&actions) == 0 else { throw GuardError.spawn }
            defer { posix_spawn_file_actions_destroy(&actions) }
            guard posix_spawn_file_actions_adddup2(&actions, channel.descriptor, 198) == 0 else { throw GuardError.spawn }
            var arguments = ["/usr/bin/python3", "-c", script, scenario, marker].map { strdup($0) } + [nil]
            defer { arguments.compactMap { $0 }.forEach { free($0) } }
            var pid: pid_t = 0
            let error = arguments.withUnsafeMutableBufferPointer {
                posix_spawn(&pid, "/usr/bin/python3", &actions, nil, $0.baseAddress!, environ)
            }
            guard error == 0 else { throw GuardError.spawn }
            return pid
        }
    }
}
