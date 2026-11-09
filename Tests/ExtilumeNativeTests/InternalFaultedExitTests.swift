import Darwin
import Foundation
import XCTest
import ExtilumeCore
@testable import ExtilumeNative

private final class FaultedExitResults: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedStatuses: [PrimarySessionStatus] = []
    private var recordedCompletion: Bool?

    func append(_ status: PrimarySessionStatus) { lock.withLock { recordedStatuses.append(status) } }
    func complete(_ value: Bool) { lock.withLock { recordedCompletion = value } }
    var statuses: [PrimarySessionStatus] { lock.withLock { recordedStatuses } }
    var completion: Bool? { lock.withLock { recordedCompletion } }
}

private final class FaultedExitFactoryState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var spawnedPIDs: [pid_t] = []

    func nextIndex() -> Int { lock.withLock { defer { count += 1 }; return count } }
    func appendPID(_ pid: pid_t) { lock.withLock { spawnedPIDs.append(pid) } }
    var calls: Int { lock.withLock { count } }
    var pids: [pid_t] { lock.withLock { spawnedPIDs } }
}

private struct FaultedExitVerifierCall: Sendable {
    let expectation: InternalApplicationExpectation?
    let requiresGuardProof: Bool
    let expectedRecord: RecoveryRecord?
    let returnedRecord: RecoveryRecord?
}

private final class FaultedExitVerifierState: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedCalls: [FaultedExitVerifierCall] = []

    func append(_ call: FaultedExitVerifierCall) { lock.withLock { recordedCalls.append(call) } }
    var calls: [FaultedExitVerifierCall] { lock.withLock { recordedCalls } }
}

private final class FaultedExitClock: @unchecked Sendable {
    private let lock = NSLock()
    private let initial: UInt64 = 50_000
    private var pastDeadline = false

    func advanceAfterFinalVerifier() { lock.withLock { pastDeadline = true } }
    func now() -> UInt64 {
        lock.withLock {
            pastDeadline ? initial + 10_000_000_001 : initial
        }
    }
}

private enum SecondPeerBehavior: String {
    case success
    case wrongExpectation = "wrong-expectation"
    case faulted
    case missingFinished = "missing-finished"
}

@MainActor
private struct FaultedExitRun {
    let directory: URL
    let controller: InternalApplicationController
    let ownedRecord: RecoveryRecord
    let restoredRecord: RecoveryRecord
    let results: FaultedExitResults
    let factoryState: FaultedExitFactoryState
    let verifierState: FaultedExitVerifierState
    let firstCommandURL: URL
    let secondCommandURL: URL
    let firstExitURL: URL
    let helperExitURL: URL
    let secondExitURL: URL
    let recordURL: URL
    let firstDiagnosticURL: URL
    let secondDiagnosticURL: URL
}

@MainActor
final class InternalFaultedExitTests: XCTestCase {
    func testRecoveryOnlyQuitWithoutNewHelperCanPublishPreviouslyVerifiedRestoration() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let record = try restoredRecord(session: UUID())
        try saveRecord(record, to: directory)
        let recordURL = directory.appendingPathComponent("recovery-record.json")
        let expectationURL = directory.appendingPathComponent("expectation.json")
        let receiptURL = directory.appendingPathComponent("receipt.json")
        try write(InternalApplicationEvent.expectation(InternalApplicationExpectation(record: record)), to: expectationURL)
        let unused = directory.appendingPathComponent("unused").path
        let results = FaultedExitResults()
        let controller = try InternalApplicationController(directory: directory, processFactory: { _, channel in
            try Self.spawnPeer(["recovery-only", unused, unused, recordURL.path, expectationURL.path,
                unused, unused, unused, unused, unused, unused,
                directory.appendingPathComponent("peer-exit").path, unused,
                directory.appendingPathComponent("peer-diagnostic.json").path], channel: channel)
        }, restorationVerifier: { directory, expectation, _, _ in
            let loaded = try Self.loadRecord(from: directory)
            guard let loaded, expectation?.matchesRestoredRecord(loaded) == true else {
                throw RecoveryError.unfinishedTransaction
            }
            return loaded
        }, restorationReceipt: { restored, expectation in
            guard !FileManager.default.fileExists(atPath: recordURL.path),
                  expectation.matchesRestoredRecord(restored) else { throw RecoveryError.unfinishedTransaction }
            try JSONEncoder().encode(restored).write(to: receiptURL)
        })
        controller.quitApplication { results.complete($0) }
        XCTAssertTrue(pump { results.completion != nil })
        XCTAssertEqual(results.completion, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
    }

    func testNormalStoppedEventPublishesBatchReceiptAfterClearAndPeerExit() throws {
        let run = try makeRun(secondPeer: .success, normalStop: true)
        defer { try? FileManager.default.removeItem(at: run.directory) }
        XCTAssertEqual(run.results.completion, true, diagnostics(run))
        XCTAssertEqual(run.factoryState.calls, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.recordURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.helperExitURL.path))
        let bytes = try Data(contentsOf: run.directory.appendingPathComponent("batch-restoration.json"))
        XCTAssertEqual(try JSONDecoder().decode(RecoveryRecord.self, from: bytes), run.restoredRecord)
    }

    func testQuitAfterFaultAddsReadOnlyPeerAndClearsOnlyAfterExactProof() throws {
        let run = try makeRun(secondPeer: .success)
        defer { try? FileManager.default.removeItem(at: run.directory) }

        XCTAssertEqual(run.results.completion, true, diagnostics(run))
        XCTAssertEqual(run.factoryState.calls, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.helperExitURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.recordURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.directory.appendingPathComponent("batch-restoration.json").path))
        XCTAssertEqual(try command(in: run.firstCommandURL, key: "initial"), .start(recoveryOnly: false))
        XCTAssertEqual(try command(in: run.firstCommandURL, key: "stop"), .stop)
        XCTAssertEqual(try command(in: run.secondCommandURL), .verifyRestored(run.restoredRecord))
        XCTAssertEqual(run.verifierState.calls.map(\.expectedRecord), [nil, run.restoredRecord], diagnostics(run))
        XCTAssertEqual(run.verifierState.calls.last?.returnedRecord, run.restoredRecord)
    }

    func testSecondPeerWithDifferentSessionExpectationRetainsRecord() throws {
        let run = try makeRun(secondPeer: .wrongExpectation)
        defer { try? FileManager.default.removeItem(at: run.directory) }

        XCTAssertEqual(run.results.completion, false)
        XCTAssertEqual(run.factoryState.calls, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.secondExitURL.path))
        XCTAssertEqual(try Self.loadRecord(from: run.directory), run.restoredRecord)
        XCTAssertEqual(try command(in: run.secondCommandURL), .verifyRestored(run.restoredRecord))
    }

    func testOriginalPeerCannotChangeExpectedGenerationAfterFault() throws {
        let run = try makeRun(secondPeer: .success, changeExpectationAfterFault: true)
        defer { try? FileManager.default.removeItem(at: run.directory) }

        XCTAssertEqual(run.results.completion, false, diagnostics(run))
        XCTAssertEqual(run.factoryState.calls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: run.helperExitURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: run.secondExitURL.path))
        XCTAssertEqual(try Self.loadRecord(from: run.directory), run.restoredRecord)
    }

    func testFaultedOrUnfinishedSecondPeerRetainsRecordWithoutThirdPeer() throws {
        for behavior in [SecondPeerBehavior.faulted, .missingFinished] {
            let run = try makeRun(secondPeer: behavior)
            defer { try? FileManager.default.removeItem(at: run.directory) }

            XCTAssertEqual(run.results.completion, false, "\(behavior.rawValue)")
            XCTAssertEqual(run.factoryState.calls, 2, "\(behavior.rawValue)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: run.secondExitURL.path), "\(behavior.rawValue)")
            XCTAssertEqual(try Self.loadRecord(from: run.directory), run.restoredRecord, "\(behavior.rawValue)")
        }
    }

    func testDeadlineAfterFinalVerifierPreventsClearWithoutWatchdog() throws {
        let run = try makeRun(secondPeer: .success, advanceAfterFinalVerifier: true)
        defer { try? FileManager.default.removeItem(at: run.directory) }

        XCTAssertEqual(run.results.completion, false)
        XCTAssertEqual(run.factoryState.calls, 2)
        XCTAssertEqual(run.verifierState.calls.last?.expectedRecord, run.restoredRecord, diagnostics(run))
        XCTAssertEqual(try Self.loadRecord(from: run.directory), run.restoredRecord)
    }

    func testRestorationVerifierRejectsRecordReplacementBeforeDisplayReads() throws {
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = try restoredRecord(session: fixtureUUID("00000000-0000-4000-8000-000000000031"))
        let replacement = try restoredRecord(session: fixtureUUID("00000000-0000-4000-8000-000000000032"))
        try saveRecord(original, to: directory)
        try saveRecord(replacement, to: directory)
        let expectation = try InternalApplicationExpectation(record: original)

        XCTAssertThrowsError(try verifyInternalApplicationRestoration(
            directory: directory,
            expectation: expectation,
            requiresGuardProof: true,
            expectedRecord: original,
            snapshotReader: {
                XCTFail("replacement must be rejected before reading displays")
                throw RecoveryError.unfinishedTransaction
            },
            internalReader: { _, _, _ in
                XCTFail("replacement must be rejected before reading the internal display")
                throw RecoveryError.unfinishedTransaction
            }
        ))
    }

    private func makeRun(
        secondPeer: SecondPeerBehavior,
        advanceAfterFinalVerifier: Bool = false,
        changeExpectationAfterFault: Bool = false,
        normalStop: Bool = false
    ) throws -> FaultedExitRun {
        let directory = try makeDirectory()
        let recordURL = directory.appendingPathComponent("recovery-record.json")
        let ownedURL = directory.appendingPathComponent("owned.json")
        let restoredURL = directory.appendingPathComponent("restored.json")
        let expectationEventURL = directory.appendingPathComponent("expectation.json")
        let mismatchExpectationEventURL = directory.appendingPathComponent("mismatch-expectation.json")
        let faultedMismatchExpectationEventURL = directory.appendingPathComponent("faulted-mismatch-expectation.json")
        let appliedEventURL = directory.appendingPathComponent("applied.json")
        let faultedEventURL = directory.appendingPathComponent("faulted.json")
        let stoppedEventURL = directory.appendingPathComponent("stopped.json")
        let firstCommandURL = directory.appendingPathComponent("first-command.json")
        let secondCommandURL = directory.appendingPathComponent("second-command.json")
        let firstExitURL = directory.appendingPathComponent("first-exit")
        let helperExitURL = directory.appendingPathComponent("helper-exit")
        let secondExitURL = directory.appendingPathComponent("second-exit")
        let firstDiagnosticURL = directory.appendingPathComponent("first-peer.json")
        let secondDiagnosticURL = directory.appendingPathComponent("second-peer.json")

        let owned = try ownedRecord(session: fixtureUUID("00000000-0000-4000-8000-000000000041"))
        let restored = try restoredRecord(from: owned)
        let otherSession = try ownedRecord(session: fixtureUUID("00000000-0000-4000-8000-000000000042"))
        let nextGeneration = try nextOwnedGeneration(from: owned)
        let expectation = try InternalApplicationExpectation(record: owned)
        let mismatch = try InternalApplicationExpectation(record: otherSession)
        let faultedMismatch = try InternalApplicationExpectation(record: nextGeneration)
        try write(owned, to: ownedURL)
        try write(restored, to: restoredURL)
        try write(InternalApplicationEvent.expectation(expectation), to: expectationEventURL)
        try write(InternalApplicationEvent.expectation(mismatch), to: mismatchExpectationEventURL)
        try write(InternalApplicationEvent.expectation(faultedMismatch), to: faultedMismatchExpectationEventURL)
        try write(InternalApplicationEvent.status(.applied), to: appliedEventURL)
        try write(InternalApplicationEvent.faulted, to: faultedEventURL)
        try write(InternalApplicationEvent.stopped(faulted: !normalStop), to: stoppedEventURL)

        let results = FaultedExitResults()
        let factoryState = FaultedExitFactoryState()
        let verifierState = FaultedExitVerifierState()
        let clock = FaultedExitClock()
        let factory = peerFactory(
            state: factoryState,
            behavior: secondPeer,
            changeExpectationAfterFault: changeExpectationAfterFault,
            normalStop: normalStop,
            ownedURL: ownedURL,
            restoredURL: restoredURL,
            recordURL: recordURL,
            expectationEventURL: expectationEventURL,
            mismatchExpectationEventURL: mismatchExpectationEventURL,
            faultedMismatchExpectationEventURL: faultedMismatchExpectationEventURL,
            appliedEventURL: appliedEventURL,
            faultedEventURL: faultedEventURL,
            stoppedEventURL: stoppedEventURL,
            firstCommandURL: firstCommandURL,
            secondCommandURL: secondCommandURL,
            firstExitURL: firstExitURL,
            helperExitURL: helperExitURL,
            secondExitURL: secondExitURL,
            firstDiagnosticURL: firstDiagnosticURL,
            secondDiagnosticURL: secondDiagnosticURL
        )
        let verifier: InternalApplicationRestorationVerifier = { directory, expectation, requiresGuardProof, expectedRecord in
            let record = try Self.loadRecord(from: directory)
            verifierState.append(FaultedExitVerifierCall(
                expectation: expectation,
                requiresGuardProof: requiresGuardProof,
                expectedRecord: expectedRecord,
                returnedRecord: record
            ))
            if advanceAfterFinalVerifier, expectedRecord != nil { clock.advanceAfterFinalVerifier() }
            return record
        }
        let controller = try InternalApplicationController(
            directory: directory,
            processFactory: factory,
            restorationVerifier: verifier,
            now: { clock.now() },
            restorationReceipt: { record, expected in
                guard !FileManager.default.fileExists(atPath: recordURL.path),
                      expected.matchesRestoredRecord(record),
                      Self.allPeersReaped(factoryState.pids) else { throw RecoveryError.unfinishedTransaction }
                try self.write(record, to: directory.appendingPathComponent("batch-restoration.json"))
            }
        )
        controller.startApplication(registerEvents: false) { results.append($0) }
        guard pump({ results.statuses.contains(.applied) }) else {
            throw GuardChannelError.timedOut
        }
        controller.quitApplication { results.complete($0) }
        guard pump({ results.completion != nil }) else { throw GuardChannelError.timedOut }
        guard pump({ FileManager.default.fileExists(atPath: firstExitURL.path)
            && FileManager.default.fileExists(atPath: helperExitURL.path) }) else {
            throw GuardChannelError.timedOut
        }
        if factoryState.calls > 1 {
            guard pump({ FileManager.default.fileExists(atPath: secondExitURL.path) }) else {
                throw GuardChannelError.timedOut
            }
        }
        if results.completion == false {
            guard pump({
                factoryState.pids.count == factoryState.calls
                    && Self.allPeersReaped(factoryState.pids)
                    && verifierState.calls.contains { advanceAfterFinalVerifier ? $0.expectedRecord != nil : $0.expectedRecord == nil }
                    && (results.statuses.contains(.recoveryIncomplete) || results.statuses.contains(.quitFailed))
                    && Self.canLoadRecord(from: directory)
            }) else { throw GuardChannelError.timedOut }
        } else {
            guard pump({
                factoryState.pids.count == factoryState.calls
                    && Self.allPeersReaped(factoryState.pids)
                    && Self.canLoadRecord(from: directory)
            }) else { throw GuardChannelError.timedOut }
        }
        return FaultedExitRun(
            directory: directory,
            controller: controller,
            ownedRecord: owned,
            restoredRecord: restored,
            results: results,
            factoryState: factoryState,
            verifierState: verifierState,
            firstCommandURL: firstCommandURL,
            secondCommandURL: secondCommandURL,
            firstExitURL: firstExitURL,
            helperExitURL: helperExitURL,
            secondExitURL: secondExitURL,
            recordURL: recordURL,
            firstDiagnosticURL: firstDiagnosticURL,
            secondDiagnosticURL: secondDiagnosticURL
        )
    }

    private func peerFactory(
        state: FaultedExitFactoryState,
        behavior: SecondPeerBehavior,
        changeExpectationAfterFault: Bool,
        normalStop: Bool,
        ownedURL: URL,
        restoredURL: URL,
        recordURL: URL,
        expectationEventURL: URL,
        mismatchExpectationEventURL: URL,
        faultedMismatchExpectationEventURL: URL,
        appliedEventURL: URL,
        faultedEventURL: URL,
        stoppedEventURL: URL,
        firstCommandURL: URL,
        secondCommandURL: URL,
        firstExitURL: URL,
        helperExitURL: URL,
        secondExitURL: URL,
        firstDiagnosticURL: URL,
        secondDiagnosticURL: URL
    ) -> InternalApplicationProcessFactory {
        { _, channel in
            let index = state.nextIndex()
            let scriptArguments = [
                index == 0 ? (normalStop ? "owner-normal" : (changeExpectationAfterFault ? "owner-changed" : "owner")) : behavior.rawValue,
                ownedURL.path,
                restoredURL.path,
                recordURL.path,
                expectationEventURL.path,
                mismatchExpectationEventURL.path,
                faultedMismatchExpectationEventURL.path,
                appliedEventURL.path,
                faultedEventURL.path,
                stoppedEventURL.path,
                (index == 0 ? firstCommandURL : secondCommandURL).path,
                (index == 0 ? firstExitURL : secondExitURL).path,
                helperExitURL.path,
                (index == 0 ? firstDiagnosticURL : secondDiagnosticURL).path
            ]
            let pid = try Self.spawnPeer(scriptArguments, channel: channel)
            state.appendPID(pid)
            return pid
        }
    }

    nonisolated private static func spawnPeer(_ scriptArguments: [String], channel: GuardChannel) throws -> pid_t {
        let script = #"""
        import json, os, socket, struct, sys, time, uuid
        mode, owned, restored, record, expectation, mismatch, faulted_mismatch, applied, faulted, stopped, command_log, peer_exit, helper_exit, diagnostic = sys.argv[1:]
        step = 'spawned'
        def note_step(value, error=None):
            with open(diagnostic, 'w') as output: json.dump({'step': value, 'error': None if error is None else repr(error)}, output)
        channel = socket.socket(fileno=198)
        channel.settimeout(6)
        def exact(size):
            data = b''
            while len(data) < size:
                part = channel.recv(size-len(data))
                if not part: raise EOFError()
                data += part
            return data
        def receive(): return json.loads(exact(struct.unpack('!I', exact(4))[0]))
        def send(value):
            payload = json.dumps(value).encode()
            channel.sendall(struct.pack('!I', len(payload)) + payload)
        def send_file(path):
            with open(path) as source: send(json.load(source))
        def canonical_record(record):
            result = dict(record)
            for name in ('baseline', 'applied', 'preDisableLayout'):
                layout = result.get(name)
                if layout is not None:
                    layout = dict(layout)
                    pairs = layout['origins']
                    layout['origins'] = {str(uuid.UUID(pairs[i])): pairs[i+1] for i in range(0, len(pairs), 2)}
                    result[name] = layout
            return result
        def touch(path):
            with open(path, 'w') as marker: marker.write('done')
        try:
            request = receive()
            step = 'handshake-received'
            note_step(step)
            send({'ready': {'_0': {'challenge': request['challenge'], 'workerPID': os.getpid(), 'workerUID': os.getuid(), 'version': 1}}})
            command = receive()
            if mode == 'recovery-only':
                assert command == {'start': {'recoveryOnly': True}}
                send_file(expectation)
                send({'status': {'_0': {'applicationFailedRestored': {}}}})
                send({'finished': {}})
                touch(peer_exit)
                os._exit(0)
            if mode.startswith('owner'):
                step = 'start-received'
                note_step(step)
                assert command == {'start': {'recoveryOnly': False}}
                os.replace(owned, record)
                step = 'owned-record-written'
                note_step(step)
                peer_pid = os.getpid()
                helper_pid = os.fork()
                if helper_pid == 0:
                    channel.close()
                    deadline = time.monotonic() + 4
                    while os.getppid() == peer_pid and time.monotonic() < deadline:
                        time.sleep(0.005)
                    if os.getppid() == peer_pid: os._exit(70)
                    os.replace(restored, record)
                    touch(helper_exit)
                    os._exit(0)
                send_file(expectation)
                time.sleep(0.02)
                send({'helperStarted': {'_0': helper_pid}})
                time.sleep(0.02)
                send_file(applied)
                step = 'applied-sent'
                note_step(step)
                stop = receive()
                with open(command_log, 'w') as output: json.dump({'initial': command, 'stop': stop}, output)
                assert stop == {'stop': {}}
                if mode != 'owner-normal':
                    send_file(faulted)
                    assert receive() == {'stop': {}}
                step = 'faulted-acknowledged'
                note_step(step)
                if mode == 'owner-changed':
                    send_file(faulted_mismatch)
                    step = 'changed-expectation-sent'
                    note_step(step)
                    touch(peer_exit)
                    os._exit(0)
                send_file(stopped)
                step = 'stopped-sent'
                note_step(step)
                touch(peer_exit)
                os._exit(0)

            step = 'verify-command-received'
            note_step(step)
            with open(command_log, 'w') as output: json.dump(command, output)
            with open(record) as source: expected_record = json.load(source)
            assert set(command) == {'verifyRestored'} and set(command['verifyRestored']) == {'_0'}
            assert canonical_record(command['verifyRestored']['_0']) == canonical_record(expected_record), (command, expected_record)
            send_file(mismatch if mode == 'wrong-expectation' else expectation)
            step = 'expectation-sent'
            time.sleep(0.02)
            if mode == 'faulted':
                send_file(faulted)
            elif mode != 'missing-finished':
                send({'finished': {}})
                step = 'finished-sent'
            touch(peer_exit)
            os._exit(0)
        except BaseException as error:
            note_step(step, error)
            touch(peer_exit)
            os._exit(71)
        """#
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw GuardError.spawn }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_adddup2(&actions, channel.descriptor, 198) == 0 else {
            throw GuardError.spawn
        }
        let arguments = ["/usr/bin/python3", "-c", script] + scriptArguments
        var argv = arguments.map { strdup($0) } + [nil]
        defer { argv.compactMap { $0 }.forEach { free($0) } }
        var pid: pid_t = 0
        let error = argv.withUnsafeMutableBufferPointer {
            posix_spawn(&pid, "/usr/bin/python3", &actions, nil, $0.baseAddress!, environ)
        }
        guard error == 0 else { throw GuardError.spawn }
        return pid
    }

    private func ownedRecord(session: UUID) throws -> RecoveryRecord {
        let internalID = fixtureUUID("00000000-0000-4000-8000-000000000051")
        let externalID = fixtureUUID("00000000-0000-4000-8000-000000000052")
        let baseline = try DisplayLayout(main: internalID, origins: [
            internalID: DisplayOrigin(x: 0, y: 0),
            externalID: DisplayOrigin(x: 100, y: 0)
        ])
        let target = try internalApplicationTargetLayout(for: baseline, externalIdentity: externalID)
        let hardware = InternalDisplayHardwareIdentity(
            bootSession: fixtureUUID("00000000-0000-4000-8000-000000000053"),
            registryEntryID: 53
        )
        var record = try RecoveryRecord(
            session: session,
            baseline: baseline,
            target: target,
            internalDisplay: InternalDisplayResponsibility(
                identity: internalID,
                baseline: true,
                applied: false,
                hardwareIdentity: hardware,
                numericIDHint: 80
            )
        )
        try record.markApplying()
        let applied = try DisplayLayout(main: externalID, origins: [externalID: DisplayOrigin(x: 0, y: 0)])
        try record.confirmApplied(applied, internalEnabled: false)
        return record
    }

    private func nextOwnedGeneration(from owned: RecoveryRecord) throws -> RecoveryRecord {
        let externalID = fixtureUUID("00000000-0000-4000-8000-000000000052")
        let target = try internalApplicationTargetLayout(for: owned.baseline, externalIdentity: externalID)
        var next = owned
        try next.prepareReapplication(current: owned.applied, target: target)
        try next.markApplying()
        try next.confirmApplied(
            DisplayLayout(main: externalID, origins: [externalID: DisplayOrigin(x: 0, y: 0)]),
            internalEnabled: false
        )
        return next
    }

    private func restoredRecord(session: UUID) throws -> RecoveryRecord {
        try restoredRecord(from: ownedRecord(session: session))
    }

    private func restoredRecord(from owned: RecoveryRecord) throws -> RecoveryRecord {
        var restored = owned
        restored.beginRestoration()
        try restored.confirmRestored(actual: owned.baseline, internalEnabled: true)
        try restored.confirmIndependentGuardVerification()
        return restored
    }

    private func saveRecord(_ record: RecoveryRecord, to directory: URL) throws {
        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        try store.save(record)
    }

    nonisolated private static func loadRecord(from directory: URL) throws -> RecoveryRecord? {
        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        return try store.load()
    }

    nonisolated private static func canLoadRecord(from directory: URL) -> Bool {
        do { _ = try loadRecord(from: directory); return true }
        catch { return false }
    }

    nonisolated private static func allPeersReaped(_ pids: [pid_t]) -> Bool {
        pids.allSatisfy { kill($0, 0) == -1 && errno == ESRCH }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        try JSONEncoder().encode(value).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func command(in url: URL, key: String? = nil) throws -> InternalApplicationCommand {
        let data = try Data(contentsOf: url)
        let payload: Data
        if let key {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            payload = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object[key]))
        } else {
            payload = data
        }
        return try JSONDecoder().decode(InternalApplicationCommand.self, from: payload)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtilumeFaultExit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private func fixtureUUID(_ value: String) -> UUID { UUID(uuidString: value)! }

    private func pump(_ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(7)
        while !condition() && Date() < end {
            _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func diagnostics(_ run: FaultedExitRun) -> String {
        let first = (try? String(contentsOf: run.firstDiagnosticURL, encoding: .utf8)) ?? "missing"
        let second = (try? String(contentsOf: run.secondDiagnosticURL, encoding: .utf8)) ?? "missing"
        let command = (try? String(contentsOf: run.secondCommandURL, encoding: .utf8)) ?? "missing"
        return "statuses=\(run.results.statuses), "
            + "factories=\(run.factoryState.calls), verifiers=\(run.verifierState.calls), "
            + "firstIPC=\(first), secondIPC=\(second), secondCommand=\(command)"
    }
}
