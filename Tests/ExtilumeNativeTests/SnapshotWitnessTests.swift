import Darwin
import ExtilumeCore
import Foundation
import XCTest
@testable import ExtilumeNative

final class SnapshotWitnessTests: XCTestCase {
    private struct BulkRequest: Encodable {
        let payload: String
    }

    private struct Request: Encodable {
        let identity: UUID
        let numericIDHint: UInt32
        let hardwareIdentity: InternalDisplayHardwareIdentity?

        init(identity: UUID, numericIDHint: UInt32, hardwareIdentity: InternalDisplayHardwareIdentity? = nil) {
            self.identity = identity
            self.numericIDHint = numericIDHint
            self.hardwareIdentity = hardwareIdentity
        }
    }

    private struct ExternalRequest: Encodable {
        let identity: ExternalDisplayIdentity
        let numericIDHint: UInt32
    }

    private let identity = UUID(uuidString: "00000000-0000-4000-8000-000000000011")!
    private let hardwareIdentity = InternalDisplayHardwareIdentity(
        bootSession: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!,
        registryEntryID: 42
    )
    private let externalIdentity = ExternalDisplayIdentity(
        uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000021")!,
        registryPath: "IOService:/display/1",
        edidUUID: "EDID-1",
        bootSession: UUID(uuidString: "00000000-0000-4000-8000-000000000022")!,
        registryEntryID: 52
    )

    private func state(
        active: Bool,
        identityUUID: UUID? = nil,
        hardwareIdentity: InternalDisplayHardwareIdentity? = nil,
        reportedIdentityUUID: UUID? = nil
    ) -> InternalDisplayState {
        InternalDisplayState(
            id: 7,
            identityUUID: identityUUID ?? identity,
            isBuiltIn: true,
            isOnline: active,
            isActive: active,
            hardwareIdentity: hardwareIdentity,
            reportedIdentityUUID: reportedIdentityUUID
        )
    }

    private func externalState(identity: ExternalDisplayIdentity? = nil) -> ExternalDisplayState {
        ExternalDisplayState(id: 7, identity: identity ?? externalIdentity, isOnline: true, isActive: false)
    }

    private func descriptor(_ peer: GuardChannel) throws -> Int32 {
        let copied = dup(peer.descriptor)
        guard copied >= 0 else { throw GuardChannelError.systemCall(errno) }
        return copied
    }

    private func rawSocketPair() throws -> (GuardChannel, Int32) {
        var descriptors: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
            throw GuardChannelError.systemCall(errno)
        }
        do {
            let client = try GuardChannel(descriptor: descriptors[0])
            return (client, descriptors[1])
        } catch {
            Darwin.close(descriptors[0])
            Darwin.close(descriptors[1])
            throw error
        }
    }

    private func framed<T: Encodable>(_ value: T) throws -> Data {
        try framed(JSONEncoder().encode(value))
    }

    private func framed(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var result = withUnsafeBytes(of: &length) { Data($0) }
        result.append(payload)
        return result
    }

    private func octalEscapes(_ bytes: Data) -> String {
        bytes.map { String(format: "\\%03o", Int($0)) }.joined()
    }

    private func spawnFixture(
        arguments: [String],
        channel: GuardChannel,
        frame: Data?,
        exitCode: Int32,
        slowExit: Bool,
        readRequest: Bool = true,
        replyDelay: TimeInterval = 0,
        hardwareIdentity: InternalDisplayHardwareIdentity?,
        expectedArguments: [String] = ["--internal-display-snapshot"]
    ) throws -> pid_t {
        XCTAssertEqual(arguments, expectedArguments)

        var script = ""
        if readRequest {
            let request = Request(identity: identity, numericIDHint: 7, hardwareIdentity: hardwareIdentity)
            let requestLength = try JSONEncoder().encode(request).count + 4
            script += "dd bs=1 count=\(requestLength) <&198 >/dev/null 2>/dev/null\n"
        }
        if replyDelay > 0 { script += "/bin/sleep \(replyDelay)\n" }
        if let frame {
            script += "printf '%b' '\(octalEscapes(frame))' >&198\n"
        }
        if slowExit {
            script += "exec /bin/sleep 3\n"
        } else {
            script += "exit \(exitCode)\n"
        }

        let inheritedDescriptor: Int32 = 198
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SnapshotWitnessError.spawnFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard posix_spawn_file_actions_addinherit_np(&actions, descriptor) == 0 else {
                throw SnapshotWitnessError.spawnFailed
            }
        }
        guard posix_spawn_file_actions_adddup2(&actions, channel.descriptor, inheritedDescriptor) == 0 else {
            throw SnapshotWitnessError.spawnFailed
        }

        var attributes: posix_spawnattr_t?
        guard posix_spawnattr_init(&attributes) == 0 else { throw SnapshotWitnessError.spawnFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)) == 0 else {
            throw SnapshotWitnessError.spawnFailed
        }

        let strings = ["/bin/sh", "-c", script].map { strdup($0)! }
        defer { strings.forEach { free($0) } }
        var childArguments: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
        var child: pid_t = 0
        let result = childArguments.withUnsafeMutableBufferPointer {
            posix_spawn(&child, "/bin/sh", &actions, &attributes, $0.baseAddress!, environ)
        }
        guard result == 0, child > 1 else { throw SnapshotWitnessError.spawnFailed }
        return child
    }

    private func runWitness(
        frame: Data?,
        exitCode: Int32 = 0,
        slowExit: Bool = false,
        hardwareIdentity: InternalDisplayHardwareIdentity? = nil,
        deadlineNanoseconds: UInt64? = nil,
        checkAccess: (() throws -> Void)? = nil,
        replyDelay: TimeInterval = 0,
        trace: ((InternalLifecycleStage) -> Void)? = nil
    ) -> (result: Result<InternalDisplayState, Error>, process: pid_t?) {
        var process: pid_t?
        let result = Result<InternalDisplayState, Error> {
            try freshInternalDisplay(
                identity: identity,
                numericIDHint: 7,
                hardwareIdentity: hardwareIdentity,
                diagnosticRole: .witness,
                trace: trace,
                deadlineNanoseconds: deadlineNanoseconds,
                checkAccess: checkAccess,
                spawn: { arguments, channel in
                    let child = try spawnFixture(
                        arguments: arguments,
                        channel: channel,
                        frame: frame,
                        exitCode: exitCode,
                        slowExit: slowExit,
                        readRequest: true,
                        replyDelay: replyDelay,
                        hardwareIdentity: hardwareIdentity
                    )
                    process = child
                    return child
                }
            )
        }
        return (result, process)
    }

    @discardableResult
    private func assertFailure(
        _ result: Result<InternalDisplayState, Error>,
        equals expected: SnapshotWitnessError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Error? {
        switch result {
        case .success:
            XCTFail("expected \(expected)", file: file, line: line)
            return nil
        case .failure(let error):
            XCTAssertEqual(error as? SnapshotWitnessError, expected, file: file, line: line)
            return error
        }
    }

    private func assertAlreadyReaped(_ process: pid_t, file: StaticString = #filePath, line: UInt = #line) {
        var status: Int32 = 0
        let result = waitpid(process, &status, WNOHANG)
        let waitError = errno
        XCTAssertEqual(result, -1, file: file, line: line)
        XCTAssertEqual(waitError, ECHILD, file: file, line: line)
        if result == 0 || (result == -1 && waitError != ECHILD) {
            _ = kill(process, SIGKILL)
            _ = waitpid(process, &status, 0)
        }
    }

    private func afterWakeLifecycle() -> InternalSessionLifecycle {
        var lifecycle = InternalSessionLifecycle()
        lifecycle.willSleep()
        lifecycle.finishSleepPreparation(acknowledged: true)
        lifecycle.didWake()
        return lifecycle
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
        let reply = try client.receive(InternalDisplayReply.self)
        let received = try reply.get()
        XCTAssertEqual(received, expected)
        XCTAssertFalse(received.isEnabled)
        XCTAssertTrue(received.matches(identity: identity))
    }

    func testChangedStateIsSentAfterTwoValidReads() throws {
        let (client, server) = try GuardChannel.pair()
        try client.send(Request(identity: identity, numericIDHint: 7))
        var reads = 0
        try serveInternalDisplay(descriptor: descriptor(server)) { _, _, _ in
            reads += 1
            return self.state(active: reads == 1)
        }
        XCTAssertEqual(reads, 2)
        let reply = try client.receive(InternalDisplayReply.self)
        switch reply {
        case .stateChanged:
            break
        case .state:
            XCTFail("expected stateChanged after valid differing reads")
        case .internalInformationUnavailable:
            XCTFail("valid differing reads must not report information unavailable")
        }
    }

    func testTemporaryInformationUnavailableIsSentWithoutDisplayPayload() throws {
        for unavailableOnRead in [1, 2] {
            let (client, server) = try GuardChannel.pair()
            try client.send(Request(identity: identity, numericIDHint: 7, hardwareIdentity: hardwareIdentity))
            var reads = 0
            try serveInternalDisplay(descriptor: descriptor(server)) { _, _, _ in
                reads += 1
                if reads == unavailableOnRead { throw SnapshotWitnessError.internalInformationUnavailable }
                return self.state(active: false, hardwareIdentity: self.hardwareIdentity, reportedIdentityUUID: self.identity)
            }

            XCTAssertEqual(reads, unavailableOnRead)
            let reply = try client.receive(InternalDisplayReply.self)
            guard case .internalInformationUnavailable = reply else {
                return XCTFail("only the typed unavailable reply is allowed")
            }
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(reply)) as? [String: Any])
            XCTAssertEqual(Set(object.keys), ["internalInformationUnavailable"])
            let payload = try XCTUnwrap(object["internalInformationUnavailable"] as? [String: Any])
            XCTAssertTrue(payload.isEmpty)
            XCTAssertThrowsError(try reply.get()) { error in
                XCTAssertEqual(error as? SnapshotWitnessError, .internalInformationUnavailable)
            }
        }
    }

    func testChildStateChangedReplyFeedsOnlyBoundedWakeRetries() throws {
        let frame = try framed(InternalDisplayReply.stateChanged)
        for attempt in 0...2 {
            let run = runWitness(frame: frame)
            let error = assertFailure(run.result, equals: .internalStateChanged)
            assertAlreadyReaped(try XCTUnwrap(run.process))
            guard let error else { continue }

            let delay = internalWakeVerificationRetryDelay(error: error, attempt: attempt, lifecycle: afterWakeLifecycle())
            if attempt < 2 {
                XCTAssertEqual(delay, 0.3)
            } else {
                XCTAssertNil(delay)
            }
        }
    }

    func testTemporaryInformationUnavailableRequiresSuccessfulChildExitAndIsNotRetryable() throws {
        let frame = try framed(InternalDisplayReply.internalInformationUnavailable)
        let normal = runWitness(frame: frame, hardwareIdentity: hardwareIdentity)
        let normalError = assertFailure(normal.result, equals: .internalInformationUnavailable)
        assertAlreadyReaped(try XCTUnwrap(normal.process))
        if let normalError {
            XCTAssertNil(internalWakeVerificationRetryDelay(error: normalError, attempt: 0, lifecycle: afterWakeLifecycle()))
        }

        let abnormal = runWitness(frame: frame, exitCode: 7, hardwareIdentity: hardwareIdentity)
        let abnormalError = assertFailure(abnormal.result, equals: .processFailed)
        assertAlreadyReaped(try XCTUnwrap(abnormal.process))
        if let abnormalError {
            XCTAssertNil(internalWakeVerificationRetryDelay(error: abnormalError, attempt: 0, lifecycle: afterWakeLifecycle()))
        }
    }

    func testNoReplyTimeoutTracesReplyWaitAndCleansUpChild() throws {
        var stages: [InternalLifecycleStage] = []
        let run = runWitness(frame: nil, slowExit: true, trace: { stages.append($0) })

        guard let error = assertFailure(run.result, equals: .timedOut) else { return }
        XCTAssertEqual(stages, [
            .witnessSpawnStarted, .witnessSpawnFinished,
            .witnessRequestStarted, .witnessRequestFinished,
            .witnessReplyStarted, .witnessFailed,
            .witnessCleanupStarted, .witnessCleanupFinished
        ])
        XCTAssertNil(internalWakeVerificationRetryDelay(error: error, attempt: 0, lifecycle: afterWakeLifecycle()))
        XCTAssertNil(internalWakeInformationRetryDelay(error: error, elapsed: 0, lifecycle: afterWakeLifecycle()))
        assertAlreadyReaped(try XCTUnwrap(run.process))
    }

    func testWakeRequestCanReceiveValidStateAfterDefaultTwoSecondTimeout() throws {
        let expected = state(active: false, hardwareIdentity: hardwareIdentity, reportedIdentityUUID: identity)
        let run = runWitness(frame: try framed(InternalDisplayReply.state(expected)),
                             hardwareIdentity: hardwareIdentity,
                             deadlineNanoseconds: try ExtilumeCore.ContinuousClock.nanoseconds() + 3_000_000_000,
                             replyDelay: 2.15)
        XCTAssertEqual(try run.result.get(), expected)
        assertAlreadyReaped(try XCTUnwrap(run.process))
    }

    func testWakeReplyCannotAcquireExtraExitTimeOrBecomeInformationRetryAfterDeadline() throws {
        let run = runWitness(frame: try framed(InternalDisplayReply.internalInformationUnavailable),
                             slowExit: true, hardwareIdentity: hardwareIdentity,
                             deadlineNanoseconds: try ExtilumeCore.ContinuousClock.nanoseconds() + 80_000_000)
        let error = try XCTUnwrap(assertFailure(run.result, equals: .timedOut))
        XCTAssertNil(internalWakeInformationRetryDelay(error: error, elapsed: 0, lifecycle: afterWakeLifecycle()))
        assertAlreadyReaped(try XCTUnwrap(run.process))
    }

    func testWakeReadAccessInterruptionKeepsOriginalErrorAndReapsChild() throws {
        for failure: Error in [InternalPowerGateError.suspended, GuardError.protectionLost, RecoveryError.unfinishedTransaction] {
            let started = try ExtilumeCore.ContinuousClock.nanoseconds()
            let run = runWitness(frame: nil, slowExit: true,
                                 deadlineNanoseconds: started + 500_000_000,
                                 checkAccess: {
                                     if try ExtilumeCore.ContinuousClock.nanoseconds() >= started + 40_000_000 { throw failure }
                                 })
            switch run.result {
            case .success: XCTFail("revoked wake read accepted")
            case .failure(let error):
                XCTAssertEqual(String(reflecting: type(of: error)), String(reflecting: type(of: failure)))
                XCTAssertNil(error as? SnapshotWitnessError)
            }
            assertAlreadyReaped(try XCTUnwrap(run.process))
        }
    }

    func testWakeReadAndExitObserveConcurrentPowerRevocationAndReapChild() throws {
        for stage in [InternalLifecycleStage.witnessReplyStarted, .witnessExitStarted] {
            let gate = InternalPowerGate()
            gate.didRegister()
            let mayRevoke = DispatchSemaphore(value: 0)
            let revocationFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                defer { revocationFinished.signal() }
                guard mayRevoke.wait(timeout: .now() + 2) == .success else { return }
                if stage == .witnessReplyStarted {
                    _ = gate.willSleep()
                    gate.didAcknowledgeSleep(true)
                } else {
                    gate.invalidate()
                }
            }
            defer {
                mayRevoke.signal()
                XCTAssertEqual(revocationFinished.wait(timeout: .now() + 2), .success)
            }

            var waiting = false
            let frame = stage == .witnessExitStarted
                ? try framed(InternalDisplayReply.internalInformationUnavailable) : nil
            let run = runWitness(
                frame: frame, slowExit: true, hardwareIdentity: hardwareIdentity,
                deadlineNanoseconds: try ExtilumeCore.ContinuousClock.nanoseconds() + 2_000_000_000,
                checkAccess: {
                    try gate.check()
                    if waiting { mayRevoke.signal() }
                },
                trace: { if $0 == stage { waiting = true } }
            )
            switch run.result {
            case .success: XCTFail("revoked wake read accepted")
            case .failure(let error):
                XCTAssertEqual(error as? InternalPowerGateError,
                               stage == .witnessReplyStarted ? .suspended : .unavailable)
                XCTAssertNil(internalWakeInformationRetryDelay(error: error, elapsed: 0, lifecycle: afterWakeLifecycle()))
            }
            XCTAssertTrue(waiting)
            assertAlreadyReaped(try XCTUnwrap(run.process))
        }
    }

    func testWakeDeadlineIncludesSpawnAndRejectsLateBufferedReply() throws {
        let run = runWitness(frame: try framed(InternalDisplayReply.internalInformationUnavailable),
                             hardwareIdentity: hardwareIdentity,
                             deadlineNanoseconds: try ExtilumeCore.ContinuousClock.nanoseconds() + 30_000_000,
                             trace: { stage in
                                 if stage == .witnessSpawnFinished { Thread.sleep(forTimeInterval: 0.05) }
                             })
        assertFailure(run.result, equals: .timedOut)
        assertAlreadyReaped(try XCTUnwrap(run.process))
    }

    func testValidReplySlowExitTimeoutTracesExitWaitAndCleansUpChild() throws {
        var stages: [InternalLifecycleStage] = []
        let expected = state(
            active: false,
            hardwareIdentity: hardwareIdentity,
            reportedIdentityUUID: identity
        )
        let run = runWitness(
            frame: try framed(InternalDisplayReply.state(expected)),
            slowExit: true,
            hardwareIdentity: hardwareIdentity,
            trace: { stages.append($0) }
        )

        guard let error = assertFailure(run.result, equals: .timedOut) else { return }
        XCTAssertEqual(stages, [
            .witnessSpawnStarted, .witnessSpawnFinished,
            .witnessRequestStarted, .witnessRequestFinished,
            .witnessReplyStarted, .witnessReplyFinished,
            .witnessExitStarted, .witnessFailed,
            .witnessCleanupStarted, .witnessCleanupFinished
        ])
        XCTAssertNil(internalWakeVerificationRetryDelay(error: error, attempt: 0, lifecycle: afterWakeLifecycle()))
        assertAlreadyReaped(try XCTUnwrap(run.process))
    }

    func testBlockedRequestSendTimeoutStopsBeforeRequestFinishedAndReapsChild() throws {
        var stages: [InternalLifecycleStage] = []
        var sendError: Error?
        var process: pid_t?
        let result = Result<InternalDisplayReply, Error> {
            try freshWitness(
                InternalDisplayReply.self,
                arguments: ["--internal-display-snapshot"],
                spawn: { arguments, channel in
                    let child = try spawnFixture(
                        arguments: arguments,
                        channel: channel,
                        frame: nil,
                        exitCode: 0,
                        slowExit: true,
                        readRequest: false,
                        hardwareIdentity: nil
                    )
                    process = child
                    return child
                },
                prepare: { channel, _ in
                    let payload = BulkRequest(payload: String(repeating: "x", count: 3_000))
                    do {
                        for _ in 0..<4_096 {
                            try channel.send(payload)
                        }
                    } catch {
                        sendError = error
                        throw error
                    }
                },
                trace: { stages.append($0) },
                validate: { _ in true }
            )
        }

        guard case .failure(let error) = result else {
            XCTFail("blocked send should surface as a witness timeout")
            return
        }
        XCTAssertEqual(error as? SnapshotWitnessError, .timedOut)
        XCTAssertEqual(sendError as? GuardChannelError, .timedOut)
        XCTAssertEqual(stages, [
            .witnessSpawnStarted, .witnessSpawnFinished,
            .witnessRequestStarted, .witnessFailed,
            .witnessCleanupStarted, .witnessCleanupFinished
        ])
        XCTAssertNil(internalWakeVerificationRetryDelay(error: error, attempt: 0, lifecycle: afterWakeLifecycle()))
        assertAlreadyReaped(try XCTUnwrap(process))
    }

    func testSuccessfulReplyCompletesWitnessPhasesWithoutCleanup() throws {
        var stages: [InternalLifecycleStage] = []
        let expected = state(
            active: false,
            hardwareIdentity: hardwareIdentity,
            reportedIdentityUUID: identity
        )
        let run = runWitness(
            frame: try framed(InternalDisplayReply.state(expected)),
            hardwareIdentity: hardwareIdentity,
            trace: { stages.append($0) }
        )

        XCTAssertEqual(try run.result.get(), expected)
        XCTAssertEqual(stages, [
            .witnessSpawnStarted, .witnessSpawnFinished,
            .witnessRequestStarted, .witnessRequestFinished,
            .witnessReplyStarted, .witnessReplyFinished,
            .witnessExitStarted, .witnessExitFinished
        ])
        assertAlreadyReaped(try XCTUnwrap(run.process))
    }

    func testTemporaryInformationUnavailableReplyRequiresValidRequestProof() throws {
        let frame = try framed(InternalDisplayReply.internalInformationUnavailable)
        let invalidProof = InternalDisplayHardwareIdentity(
            bootSession: hardwareIdentity.bootSession,
            registryEntryID: 0
        )
        let untrustedProofs: [InternalDisplayHardwareIdentity?] = [nil, invalidProof]
        for proof in untrustedProofs {
            let run = runWitness(frame: frame, hardwareIdentity: proof)
            assertFailure(run.result, equals: .invalidSnapshot)
            assertAlreadyReaped(try XCTUnwrap(run.process))
        }
    }

    func testWakeRetryHonorsFaultStopAndManualPauseState() throws {
        let changed = SnapshotWitnessError.internalStateChanged

        var faulted = afterWakeLifecycle()
        faulted.fail()
        XCTAssertNil(internalWakeVerificationRetryDelay(error: changed, attempt: 0, lifecycle: faulted))

        var stopped = afterWakeLifecycle()
        stopped.requestStop()
        XCTAssertNil(internalWakeVerificationRetryDelay(error: changed, attempt: 0, lifecycle: stopped))

        var manuallyPaused = afterWakeLifecycle()
        manuallyPaused.requestPause()
        XCTAssertTrue(manuallyPaused.shouldRecoverAfterWake)
        XCTAssertFalse(manuallyPaused.shouldResumeAfterWake)
        XCTAssertEqual(internalWakeVerificationRetryDelay(error: changed, attempt: 0, lifecycle: manuallyPaused), 0.3)
        manuallyPaused.didRestore()
        XCTAssertTrue(manuallyPaused.paused)
        XCTAssertFalse(manuallyPaused.shouldRecoverAfterWake)
        XCTAssertFalse(manuallyPaused.shouldResumeAfterWake)
        XCTAssertNil(internalWakeVerificationRetryDelay(error: changed, attempt: 0, lifecycle: manuallyPaused))
    }

    func testSuccessfulChildStateStillVerifiesIdentityAndHardwareProof() throws {
        let expected = state(
            active: false,
            hardwareIdentity: hardwareIdentity,
            reportedIdentityUUID: identity
        )
        let run = runWitness(frame: try framed(InternalDisplayReply.state(expected)), hardwareIdentity: hardwareIdentity)
        let received = try run.result.get()
        XCTAssertEqual(received, expected)
        XCTAssertTrue(received.matches(identity: identity, hardwareIdentity: hardwareIdentity))
        assertAlreadyReaped(try XCTUnwrap(run.process))
    }

    func testParentRejectsInvalidStateFromNormallyExitingChild() throws {
        let wrongIdentity = state(active: false,
            identityUUID: UUID(uuidString: "00000000-0000-4000-8000-000000000013")!,
            hardwareIdentity: hardwareIdentity, reportedIdentityUUID: identity)
        let wrongProof = state(active: false,
            hardwareIdentity: InternalDisplayHardwareIdentity(bootSession: hardwareIdentity.bootSession, registryEntryID: 43),
            reportedIdentityUUID: identity)
        let missingReportedIdentity = state(active: false, hardwareIdentity: hardwareIdentity)
        for invalid in [wrongIdentity, wrongProof, missingReportedIdentity] {
            let run = runWitness(frame: try framed(InternalDisplayReply.state(invalid)), hardwareIdentity: hardwareIdentity)
            let error = assertFailure(run.result, equals: .invalidSnapshot)
            assertAlreadyReaped(try XCTUnwrap(run.process))
            if let error {
                XCTAssertNil(internalWakeVerificationRetryDelay(error: error, attempt: 0, lifecycle: afterWakeLifecycle()))
            }
        }
    }

    func testStateChangedCannotMaskNonzeroOrSlowChildExit() throws {
        let frame = try framed(InternalDisplayReply.stateChanged)
        let cases: [(exitCode: Int32, slowExit: Bool, expected: SnapshotWitnessError)] = [
            (7, false, .processFailed),
            (0, true, .timedOut)
        ]
        for testCase in cases {
            let run = runWitness(frame: frame, exitCode: testCase.exitCode, slowExit: testCase.slowExit)
            let error = assertFailure(run.result, equals: testCase.expected)
            assertAlreadyReaped(try XCTUnwrap(run.process))
            if let error {
                XCTAssertNil(internalWakeVerificationRetryDelay(error: error, attempt: 0, lifecycle: afterWakeLifecycle()))
            }
        }
    }

    func testEOFMalformedAndUnknownChildRepliesAreNotWakeRetryable() throws {
        let frames: [Data?] = [
            nil,
            framed(Data("{".utf8)),
            framed(Data("{\"unknown\":{}}".utf8))
        ]
        for frame in frames {
            let run = runWitness(frame: frame)
            let error = assertFailure(run.result, equals: .communicationFailed)
            assertAlreadyReaped(try XCTUnwrap(run.process))
            if let error {
                XCTAssertNil(internalWakeVerificationRetryDelay(error: error, attempt: 0, lifecycle: afterWakeLifecycle()))
            }
        }
    }

    func testInvalidIdentityOrHardwareProofAndReaderFailuresNeverSendReply() throws {
        let valid = state(active: false)
        let wrongIdentity = state(
            active: false,
            identityUUID: UUID(uuidString: "00000000-0000-4000-8000-000000000013")!
        )
        let wrongHardwareIdentity = InternalDisplayHardwareIdentity(
            bootSession: hardwareIdentity.bootSession,
            registryEntryID: 43
        )
        let validWithProof = state(
            active: false,
            hardwareIdentity: hardwareIdentity,
            reportedIdentityUUID: identity
        )
        let wrongProof = state(
            active: false,
            hardwareIdentity: wrongHardwareIdentity,
            reportedIdentityUUID: identity
        )

        try assertRejectedServerReply(expectedReads: 1, failureCode: "witness-invalid-state") { read in
            read == 1 ? wrongIdentity : valid
        }
        try assertRejectedServerReply(expectedReads: 2, failureCode: "witness-invalid-state") { read in
            read == 1 ? valid : wrongIdentity
        }
        try assertRejectedServerReply(
            hardwareIdentity: hardwareIdentity,
            expectedReads: 1,
            failureCode: "witness-invalid-state"
        ) { read in
            read == 1 ? wrongProof : validWithProof
        }
        try assertRejectedServerReply(
            hardwareIdentity: hardwareIdentity,
            expectedReads: 2,
            failureCode: "witness-invalid-state"
        ) { read in
            read == 1 ? validWithProof : wrongProof
        }
        try assertRejectedServerReply(expectedReads: 1, failureCode: "identity-conflict") { _ in
            throw RecoveryError.identityConflict
        }
        try assertRejectedServerReply(expectedReads: 2, failureCode: "identity-conflict") { read in
            if read == 1 { return valid }
            throw RecoveryError.identityConflict
        }
        try assertRejectedServerReply(expectedReads: 1, failureCode: "witness-invalid-state") { _ in
            throw SnapshotWitnessError.internalInformationUnavailable
        }
        try assertRejectedServerReply(
            hardwareIdentity: InternalDisplayHardwareIdentity(
                bootSession: hardwareIdentity.bootSession,
                registryEntryID: 0
            ),
            expectedReads: 1,
            failureCode: "witness-invalid-state"
        ) { _ in
            throw SnapshotWitnessError.internalInformationUnavailable
        }
    }

    private func assertRejectedServerReply(
        hardwareIdentity expectedHardware: InternalDisplayHardwareIdentity? = nil,
        expectedReads: Int,
        failureCode: String,
        reader: (Int) throws -> InternalDisplayState
    ) throws {
        let (client, serverDescriptor) = try rawSocketPair()
        var ownsServerDescriptor = true
        defer {
            if ownsServerDescriptor { Darwin.close(serverDescriptor) }
        }
        try client.send(Request(identity: identity, numericIDHint: 7, hardwareIdentity: expectedHardware))

        var reads = 0
        ownsServerDescriptor = false
        var serverError: Error?
        do {
            try serveInternalDisplay(descriptor: serverDescriptor) { requestIdentity, hint, hardware in
                XCTAssertEqual(requestIdentity, self.identity)
                XCTAssertEqual(hint, 7)
                XCTAssertEqual(hardware, expectedHardware)
                reads += 1
                return try reader(reads)
            }
            XCTFail("invalid reads must not emit an internal-display reply")
        } catch {
            serverError = error
        }

        XCTAssertEqual(reads, expectedReads)
        XCTAssertEqual(serverError.map(snapshotWitnessFailureCode), failureCode)
        XCTAssertThrowsError(try client.receive(InternalDisplayReply.self)) { error in
            XCTAssertEqual(error as? GuardChannelError, .peerClosed)
        }
    }

    func testExternalIdentityConflictReplyCoversBothReadsAndWrongTarget() throws {
        let wrongIdentity = ExternalDisplayIdentity(
            uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000023")!,
            registryPath: externalIdentity.registryPath,
            edidUUID: externalIdentity.edidUUID,
            bootSession: externalIdentity.bootSession,
            registryEntryID: externalIdentity.registryEntryID
        )

        for failure in [RecoveryError.identityConflict, .invalidRecord] {
            try assertExternalIdentityReply(expectedReads: 1) { _ in
                throw failure
            }
            try assertExternalIdentityReply(expectedReads: 2) { read in
                if read == 1 { return self.externalState() }
                throw failure
            }
        }
        try assertExternalIdentityReply(expectedReads: 1) { _ in
            self.externalState(identity: wrongIdentity)
        }
    }

    private func assertExternalIdentityReply(
        expectedReads: Int,
        reader: (Int) throws -> ExternalDisplayState
    ) throws {
        let (client, serverDescriptor) = try rawSocketPair()
        var ownsServerDescriptor = true
        defer {
            if ownsServerDescriptor { Darwin.close(serverDescriptor) }
        }
        try client.send(ExternalRequest(identity: externalIdentity, numericIDHint: 7))

        var reads = 0
        ownsServerDescriptor = false
        try serveExternalDisplay(descriptor: serverDescriptor) { identity, hint in
            XCTAssertEqual(identity, self.externalIdentity)
            XCTAssertEqual(hint, 7)
            reads += 1
            return try reader(reads)
        }

        XCTAssertEqual(reads, expectedReads)
        let reply = try client.receive(ExternalDisplayReply.self)
        guard case .identityConflict = reply else {
            return XCTFail("expected an identity-conflict reply")
        }
        XCTAssertThrowsError(try reply.get()) { error in
            guard case RecoveryError.identityConflict = error else {
                return XCTFail("expected RecoveryError.identityConflict, got \(error)")
            }
        }
    }

    func testFreshExternalIdentityConflictWaitsForSuccessfulWitnessExit() throws {
        let successful = runExternalWitness(reply: .identityConflict)
        guard case .failure(let identityError) = successful.result else {
            XCTFail("identity-conflict reply should throw")
            return
        }
        guard case RecoveryError.identityConflict = identityError else {
            XCTFail("expected RecoveryError.identityConflict, got \(identityError)")
            return
        }
        assertAlreadyReaped(try XCTUnwrap(successful.process))

        let failedExit = runExternalWitness(reply: .identityConflict, exitCode: 23)
        guard case .failure(let processError) = failedExit.result else {
            XCTFail("a failed witness exit must not be hidden by identity conflict")
            return
        }
        XCTAssertEqual(processError as? SnapshotWitnessError, .processFailed)
        assertAlreadyReaped(try XCTUnwrap(failedExit.process))
    }

    func testFreshExternalRejectsWrongTargetAndKeepsDisconnectAsCommunicationFailure() throws {
        let wrongIdentity = ExternalDisplayIdentity(
            uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000024")!,
            registryPath: externalIdentity.registryPath,
            edidUUID: externalIdentity.edidUUID,
            bootSession: externalIdentity.bootSession,
            registryEntryID: externalIdentity.registryEntryID
        )
        let wrongTarget = runExternalWitness(reply: .state(externalState(identity: wrongIdentity)))
        guard case .failure(let targetError) = wrongTarget.result else {
            XCTFail("a state for another target must be rejected")
            return
        }
        XCTAssertEqual(targetError as? SnapshotWitnessError, .invalidSnapshot)
        assertAlreadyReaped(try XCTUnwrap(wrongTarget.process))

        let disconnected = runExternalWitness(reply: nil)
        guard case .failure(let communicationError) = disconnected.result else {
            XCTFail("a disconnected witness must fail")
            return
        }
        XCTAssertEqual(communicationError as? SnapshotWitnessError, .communicationFailed)
        assertAlreadyReaped(try XCTUnwrap(disconnected.process))
    }

    private func runExternalWitness(
        reply: ExternalDisplayReply?,
        exitCode: Int32 = 0
    ) -> (result: Result<ExternalDisplayState, Error>, process: pid_t?) {
        var process: pid_t?
        let result = Result<ExternalDisplayState, Error> {
            try freshExternalDisplay(
                identity: externalIdentity,
                numericIDHint: 7,
                spawn: { arguments, channel in
                    let frame: Data?
                    if let reply { frame = try self.framed(reply) }
                    else { frame = nil }
                    let child = try self.spawnFixture(
                        arguments: arguments,
                        channel: channel,
                        frame: frame,
                        exitCode: exitCode,
                        slowExit: false,
                        readRequest: false,
                        hardwareIdentity: nil,
                        expectedArguments: ["--external-display-snapshot"]
                    )
                    process = child
                    return child
                }
            )
        }
        return (result, process)
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

        var spawnCalls = 0
        XCTAssertThrowsError(try freshInternalDisplay(
            identity: identity,
            numericIDHint: 0,
            spawn: { _, _ in
                spawnCalls += 1
                throw SnapshotWitnessError.spawnFailed
            }
        ))
        XCTAssertEqual(spawnCalls, 0)
    }

    func testDiagnosticsDistinguishFailuresWithoutRenderingUnderlyingError() {
        struct PrivateError: Error, CustomStringConvertible { var description: String { "private-device-data" } }
        XCTAssertEqual(snapshotWitnessFailureCode(PrivateError()), "unclassified")
        XCTAssertEqual(snapshotWitnessFailureCode(GuardChannelError.peerClosed), "channel-closed")
        XCTAssertEqual(snapshotWitnessFailureCode(GuardChannelError.timedOut), "channel-timeout")
        XCTAssertEqual(snapshotWitnessFailureCode(SnapshotWitnessError.processFailed), "witness-exit")
        XCTAssertEqual(snapshotWitnessFailureCode(SnapshotWitnessError.spawnFailed), "witness-spawn")
        XCTAssertEqual(snapshotWitnessFailureCode(SnapshotWitnessError.cleanupFailed), "witness-cleanup")
        XCTAssertEqual(snapshotWitnessFailureCode(SnapshotWitnessError.internalInformationUnavailable), "internal-information-unavailable")
    }
    private enum RecoveryReplyFixture: Codable {
        case observation(ExternalRecoveryObservation)
        case stateChanged
        case identityConflict
    }

    private func recoveryEvidence(online: Bool = false) -> ExternalRecoveryObservation {
        .connection(ExternalConnectionEvidence(
            id: 7, observedUUID: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!,
            registryPath: externalIdentity.registryPath, edidUUID: externalIdentity.edidUUID,
            bootSession: externalIdentity.bootSession, registryEntryID: externalIdentity.registryEntryID,
            isBuiltin: false, isOnline: online, isActive: false, matchingSlotCount: 1,
            allSlotsExcludeOriginalUUID: true, registryIsHDMI: true, registryClassMatches: true
        ))
    }

    func testRecoveryWitnessRequiresTwoMatchingReadsAndMapsMetadataFailures() throws {
        for failure in [false, true] {
            let (client, server) = try rawSocketPair()
            try client.send(ExternalRequest(identity: externalIdentity, numericIDHint: 7))
            var reads = 0
            try serveExternalRecoveryObservation(descriptor: server) { _, _ in
                reads += 1
                if reads == 2 && failure { throw RecoveryError.invalidRecord }
                return self.recoveryEvidence(online: reads == 2)
            }
            XCTAssertEqual(reads, 2)
            let reply = try client.receive(RecoveryReplyFixture.self)
            if failure {
                guard case .identityConflict = reply else { return XCTFail("expected identity conflict") }
            } else {
                guard case .stateChanged = reply else { return XCTFail("expected state changed") }
            }
        }
    }

    func testRecoveryWitnessFailedExitCannotBeMaskedByReply() throws {
        var process: pid_t?
        XCTAssertThrowsError(try freshExternalRecoveryObservation(identity: externalIdentity, numericIDHint: 7,
            spawn: { arguments, channel in
                let child = try self.spawnFixture(arguments: arguments, channel: channel,
                    frame: self.framed(RecoveryReplyFixture.identityConflict), exitCode: 23,
                    slowExit: false, readRequest: false, hardwareIdentity: nil,
                    expectedArguments: ["--external-recovery-snapshot"])
                process = child
                return child
            })) { error in
                XCTAssertEqual(error as? SnapshotWitnessError, .processFailed)
            }
        assertAlreadyReaped(try XCTUnwrap(process))
    }

    func testRecoveryWitnessRejectsInvalidRequestBeforeReading() throws {
        let (client, server) = try rawSocketPair()
        try client.send(ExternalRequest(identity: externalIdentity, numericIDHint: 0))
        var reads = 0
        XCTAssertThrowsError(try serveExternalRecoveryObservation(descriptor: server) { _, _ in
            reads += 1
            return self.recoveryEvidence()
        })
        XCTAssertEqual(reads, 0)
    }

    func testRecoveryWitnessParentValidatesEvidence() throws {
        var process: pid_t?
        let wrong = ExternalRecoveryObservation.identified(ExternalDisplayState(
            id: 7, identity: ExternalDisplayIdentity(uuid: UUID(), registryPath: externalIdentity.registryPath,
                edidUUID: externalIdentity.edidUUID, bootSession: externalIdentity.bootSession,
                registryEntryID: externalIdentity.registryEntryID), isOnline: true, isActive: true))
        XCTAssertThrowsError(try freshExternalRecoveryObservation(identity: externalIdentity, numericIDHint: 7,
            spawn: { arguments, channel in
                let child = try self.spawnFixture(arguments: arguments, channel: channel,
                    frame: self.framed(RecoveryReplyFixture.observation(wrong)), exitCode: 0,
                    slowExit: false, readRequest: false, hardwareIdentity: nil,
                    expectedArguments: ["--external-recovery-snapshot"])
                process = child
                return child
            })) { error in
                XCTAssertEqual(error as? SnapshotWitnessError, .invalidSnapshot)
            }
        assertAlreadyReaped(try XCTUnwrap(process))
    }

}
