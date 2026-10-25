import Darwin
import ExtilumeCore
import Foundation

typealias InternalApplicationProcessFactory = @Sendable ([String], GuardChannel) throws -> pid_t
typealias InternalApplicationRestorationVerifier = @Sendable (
    URL, InternalApplicationExpectation?, Bool, RecoveryRecord?
) throws -> RecoveryRecord?

@MainActor
final class InternalApplicationController: PrimaryApplicationControlling {
    private let directory: URL
    private let processFactory: InternalApplicationProcessFactory
    private let restorationVerifier: InternalApplicationRestorationVerifier
    private let now: @Sendable () throws -> UInt64
    var persistFailureForExit: (@MainActor () -> Bool)?
    private var statusHandler: (@Sendable (PrimarySessionStatus) -> Void)?
    private var quitCompletion: (@Sendable (Bool) -> Void)?
    private var workerPID: pid_t?
    private var workerSource: DispatchSourceProcess?
    private var channel: GuardChannel?
    private var channelSource: DispatchSourceRead?
    private var helperPID: pid_t?
    private var helperSource: DispatchSourceProcess?
    private var expected: InternalApplicationExpectation?
    private var preflightStatus: PrimarySessionStatus?
    private var initialRecordExisted = true
    private var launchInProgress = false
    private var recoveryOnly = false
    private var quitting = false
    private var workerExited = false
    private var channelDrained = false
    private var helperExited = false
    private var verificationInProgress = false
    private var orderlyFinished = false
    private var workerSucceeded = false
    private var transportFailed = false
    private var quitWatchdog: DispatchWorkItem?
    private var finalization = InternalApplicationFinalization()
    private var workerRun = UUID()
    private var quitDeadline: UInt64?
    private var faultedQuitCandidate = false
    private var faultedStopReceived = false
    private var verifiedExitRecord: RecoveryRecord?

    init(
        directory: URL,
        processFactory: @escaping InternalApplicationProcessFactory = spawnProbe,
        restorationVerifier: @escaping InternalApplicationRestorationVerifier = {
            try verifyInternalApplicationRestoration(directory: $0, expectation: $1, requiresGuardProof: $2, expectedRecord: $3)
        },
        now: @escaping @Sendable () throws -> UInt64 = ContinuousClock.nanoseconds
    ) throws {
        _ = try RecoveryStore(directory: directory)
        self.directory = directory
        self.processFactory = processFactory
        self.restorationVerifier = restorationVerifier
        self.now = now
    }

    func startApplication(
        registerEvents: Bool = true,
        recoveryOnly: Bool = false,
        onStatus: @escaping @Sendable (PrimarySessionStatus) -> Void
    ) {
        statusHandler = onStatus
        guard workerPID == nil, !launchInProgress else { return }
        self.recoveryOnly = recoveryOnly
        quitting = false
        publish(.applying)
        launch(.start(recoveryOnly: recoveryOnly))
    }

    func retryApplication() {
        if workerPID != nil {
            send(.reapply)
        } else if !launchInProgress {
            recoveryOnly = false
            quitting = false
            publish(.applying)
            launch(.start(recoveryOnly: false))
        }
    }

    func recoverApplication() {
        if workerPID != nil {
            send(.restore)
        } else if !launchInProgress {
            recoveryOnly = true
            quitting = false
            launch(.start(recoveryOnly: true))
        }
    }

    func confirmCurrentConfiguration() {
        send(.confirmUser)
    }

    func quitApplication(completion: @escaping @Sendable (Bool) -> Void) {
        guard !quitting else { completion(false); return }
        quitCompletion = completion
        quitting = true
        let request = finalization.beginQuit()
        do {
            let (deadline, overflow) = try now().addingReportingOverflow(10_000_000_000)
            guard !overflow else { throw ClockError.overflow }
            quitDeadline = deadline
        } catch { finishQuit(success: false, status: .quitFailed); return }
        faultedQuitCandidate = false
        if workerPID == nil && !launchInProgress && !verificationInProgress { verifiedExitRecord = nil }
        quitWatchdog?.cancel()
        let watchdog = DispatchWorkItem { @Sendable [weak self] in
            Self.onMainRunLoop { [weak self] in
                guard let self, self.quitting, self.finalization.request == request else { return }
                self.finishQuit(success: false, status: .quitFailed)
            }
        }
        quitWatchdog = watchdog
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
        publish(.restoringAndQuitting)
        if workerPID != nil {
            guard channel != nil else { finishQuit(success: false, status: .quitFailed); return }
            send(.stop)
            return
        }
        guard !launchInProgress else { return }
        do {
            let store = try RecoveryStore(directory: directory)
            guard try store.load() != nil else {
                finishQuit(success: true, status: .quitFailed)
                return
            }
            recoveryOnly = true
            launch(.start(recoveryOnly: true))
        } catch {
            finishQuit(success: false, status: .quitFailed)
        }
    }

    private func launch(_ command: InternalApplicationCommand) {
        guard !launchInProgress else { return }
        do { initialRecordExisted = try RecoveryStore(directory: directory).load() != nil }
        catch {
            if quitting { finishQuit(success: false, status: .quitFailed) }
            else { publish(.recoveryIncomplete) }
            return
        }
        launchInProgress = true
        let run = UUID()
        workerRun = run
        let directory = self.directory
        let processFactory = self.processFactory
        let deadline = quitDeadline
        let readClock = now
        let verificationOnly: Bool
        if case .verifyRestored = command { verificationOnly = true } else { verificationOnly = false }
        DispatchQueue.global().async { [weak self] in
            do {
                if verificationOnly {
                    guard let deadline, try readClock() < deadline else { throw GuardError.suspended }
                }
                let (pid, result) = try Self.handshakeAttempt(
                    directory: directory, processFactory: processFactory
                )
                Self.onMainRunLoop { [weak self] in
                    guard let self, self.workerRun == run else { return }
                    self.launchInProgress = false
                    switch result {
                    case .success(let channel): self.installWorker(pid: pid, channel: channel, command: command, run: run)
                    case .failure:
                        self.trackWorker(pid, run: run)
                        self.channelDrained = true
                        self.publish(.recoveryIncomplete)
                        if self.quitting { self.finishQuit(success: false, status: .quitFailed) }
                    }
                }
            } catch {
                Self.onMainRunLoop { [weak self] in
                    guard let self, self.workerRun == run else { return }
                    self.launchInProgress = false
                    if self.quitting {
                        self.finishQuit(success: false, status: .quitFailed)
                    } else {
                        self.publish(.recoveryIncomplete)
                    }
                }
            }
        }
    }

    private nonisolated static func handshakeAttempt(
        directory: URL,
        processFactory: InternalApplicationProcessFactory
    ) throws -> (pid_t, Result<GuardChannel, Error>) {
        let (parentChannel, workerChannel) = try GuardChannel.pair()
        let challenge = UUID()
        let parentPID = getpid()
        let pid = try processFactory(
            ["--internal-app-session", directory.path, String(parentPID)], workerChannel
        )
        do {
            try parentChannel.send(InternalApplicationHandshakeRequest(
                challenge: challenge, parentPID: parentPID, parentUID: UInt32(getuid())
            ))
            let reply = try parentChannel.receive(InternalApplicationEvent.self)
            guard case .ready(let handshake) = reply,
                  handshake.challenge == challenge,
                  handshake.workerPID == pid,
                  handshake.workerUID == UInt32(getuid()),
                  handshake.version == 1,
                  kill(pid, 0) == 0 else {
                throw GuardError.identity
            }
            return (pid, .success(parentChannel))
        } catch {
            return (pid, .failure(error))
        }
    }

    private func installWorker(pid: pid_t, channel: GuardChannel, command: InternalApplicationCommand, run: UUID) {
        let command = internalApplicationCommandForPendingQuit(command, quitting: quitting)
        if case .start(let recoveryOnly) = command { self.recoveryOnly = recoveryOnly }
        if case .verifyRestored = command { self.recoveryOnly = true }
        if (quitting || verifiedExitRecord != nil) && !quitIsCurrent(finalization.request) {
            finishQuit(success: false, status: .quitFailed)
            trackWorker(pid, run: run)
            self.channelDrained = true
            return
        }
        self.channel = channel
        trackWorker(pid, run: run)
        orderlyFinished = false
        expected = nil
        preflightStatus = nil

        let input = DispatchSource.makeReadSource(fileDescriptor: channel.descriptor, queue: .global())
        input.setEventHandler { @Sendable [weak self, weak channel] in
            guard let channel else { return }
            do {
                let event = try channel.receive(InternalApplicationEvent.self)
                Self.onMainRunLoop { [weak self] in
                    guard let self, self.workerRun == run else { return }
                    self.handle(event, from: pid)
                }
            } catch {
                Self.onMainRunLoop { [weak self] in
                    guard let self, self.workerRun == run else { return }
                    self.channelDidFail(from: pid, error: error)
                }
            }
        }
        channelSource = input
        input.resume()
        send(command)
    }

    private func trackWorker(_ pid: pid_t, run: UUID) {
        workerPID = pid
        let quitRequest = finalization.request
        finalization = InternalApplicationFinalization(request: quitRequest)
        workerExited = false
        workerSucceeded = false
        transportFailed = false
        channelDrained = false
        helperExited = false
        helperPID = nil
        faultedStopReceived = false

        let process = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        process.setEventHandler { @Sendable [weak self] in
            var status: Int32 = 0
            var result: pid_t
            repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
            let succeeded = result == pid && status == 0
            Self.onMainRunLoop { [weak self] in
                guard let self, self.workerRun == run else { return }
                self.workerDidExit(pid, succeeded: succeeded)
            }
        }
        workerSource = process
        process.resume()

    }

    private func handle(_ event: InternalApplicationEvent, from pid: pid_t) {
        guard workerPID == pid else { return }
        guard !orderlyFinished else { channelDidFail(from: pid); return }
        switch event {
        case .ready:
            channelDidFail(from: pid)
        case .helperStarted(let helper):
            guard verifiedExitRecord == nil else { channelDidFail(from: pid); return }
            if preflightStatus != nil {
                preflightStatus = nil
                publish(.recoveryIncomplete)
            }
            guard helper > 1, helperPID == nil else {
                channelDidFail(from: pid)
                return
            }
            helperPID = helper
            let run = workerRun
            let process = DispatchSource.makeProcessSource(identifier: helper, eventMask: .exit, queue: .global())
            process.setEventHandler { @Sendable [weak self] in
                Self.onMainRunLoop { [weak self] in
                    guard let self, self.workerRun == run else { return }
                    self.helperDidExit(helper)
                }
            }
            helperSource = process
            process.resume()
        case .expectation(let expectation):
            do {
                try expectation.validate()
                if let verifiedExitRecord {
                    guard expectation == (try InternalApplicationExpectation(record: verifiedExitRecord)) else {
                        throw RecoveryError.identityConflict
                    }
                }
                if faultedQuitCandidate, expected != expectation { throw RecoveryError.identityConflict }
                if let expected {
                    guard expected.session == expectation.session, expected.generation <= expectation.generation else {
                        throw RecoveryError.identityConflict
                    }
                }
                self.expected = expectation
            } catch { channelDidFail(from: pid); return }
        case .status(let status):
            guard verifiedExitRecord == nil else { channelDidFail(from: pid); return }
            switch status {
            case .waiting, .unsupported(_):
                guard !initialRecordExisted, expected == nil, helperPID == nil, !recoveryOnly else {
                    channelDidFail(from: pid)
                    return
                }
                preflightStatus = status
                break
            default:
                if finalization.faulted && (status == .applied || status == .manualConfiguration) {
                    publish(.recoveryIncomplete)
                    return
                }
                if [.recoveryIncomplete, .quitFailed, .quitWaitingForDisplays].contains(status)
                    || (status == .applicationFailedRestored && !recoveryOnly) {
                    faultedQuitCandidate = false
                    noteWorkerFault()
                }
                if status == .applied && (expected == nil || helperPID == nil || helperExited) {
                    channelDidFail(from: pid)
                    return
                }
                if status == .applicationFailedRestored, recoveryOnly {
                    break
                } else if status == .quitFailed || status == .quitWaitingForDisplays, quitting {
                    finishQuit(success: false, status: status)
                } else if status == .recoveryIncomplete, quitting {
                    finishQuit(success: false, status: .quitFailed)
                } else {
                    publish(status)
                    if quitting && !recoveryOnly && [PrimarySessionStatus.applied, .manualConfiguration, .applicationFailedRestored].contains(status) {
                        send(.stop)
                    }
                }
            }
        case .finished:
            guard recoveryOnly || preflightStatus != nil else { channelDidFail(from: pid); return }
            orderlyFinished = true
        case .faulted:
            let mayVerifyExit = quitIsCurrent(finalization.request) && !recoveryOnly
                && !finalization.faulted && !transportFailed && expected != nil && helperPID != nil && !helperExited
            noteWorkerFault()
            if mayVerifyExit, persistFailureForExit?() == true, quitIsCurrent(finalization.request) {
                faultedQuitCandidate = true
                print("退出恢复遇到故障；门禁已持久锁存，等待原会话与辅助完成终验。")
                publish(.restoringAndQuitting)
            } else if quitting { finishQuit(success: false, status: .quitFailed) }
            else { publish(.recoveryIncomplete) }
        case .stopped(let faulted):
            guard verifiedExitRecord == nil else { channelDidFail(from: pid); return }
            faultedStopReceived = faulted
            finalization.noteStopped(faulted: faulted)
            if faulted {
                if quitting && faultedQuitCandidate { publish(.restoringAndQuitting) }
                else if quitting { finishQuit(success: false, status: .quitFailed) }
                else { publish(.recoveryIncomplete) }
            }
        case .failed:
            faultedQuitCandidate = false
            noteWorkerFault()
            if quitting { finishQuit(success: false, status: .quitFailed) }
            else { publish(.recoveryIncomplete) }
        }
    }

    private func noteWorkerFault() {
        let first = !finalization.faulted
        finalization.noteFault()
        if first, workerPID != nil, channel != nil { send(.stop) }
    }

    private func workerDidExit(_ pid: pid_t, succeeded: Bool) {
        guard workerPID == pid, !workerExited else { return }
        workerExited = true
        workerSucceeded = succeeded
        workerSource?.cancel()
        workerSource = nil
        verifyIfFinished()
    }

    private func helperDidExit(_ pid: pid_t) {
        guard helperPID == pid, !helperExited else { return }
        helperExited = true
        helperSource?.cancel()
        helperSource = nil
        verifyIfFinished()
    }

    private func channelDidFail(from pid: pid_t, error: Error? = nil) {
        guard workerPID == pid else { return }
        channelSource?.cancel()
        channelSource = nil
        channel = nil
        channelDrained = true
        let cleanEnd = error as? GuardChannelError == .peerClosed
        if !cleanEnd || (!quitting && !orderlyFinished && !recoveryOnly) {
            faultedQuitCandidate = false
            transportFailed = true
            finalization.noteFault()
        }
        if workerExited || (error as? GuardChannelError == .peerClosed && (quitting || orderlyFinished)) {
            verifyIfFinished()
            return
        }
        if quitting { finishQuit(success: false, status: .quitFailed) }
        else { publish(.recoveryIncomplete) }
    }

    private func verifyIfFinished() {
        guard workerExited, channelDrained, !verificationInProgress else { return }
        if preflightStatus != nil, helperPID != nil {
            finishVerification(success: false, waitingForDisplays: false)
            return
        }
        if !recoveryOnly && helperPID == nil && preflightStatus == nil && !finalization.stoppedNormally {
            finishVerification(success: false, waitingForDisplays: false)
            return
        }
        guard recoveryOnly || helperExited || ((preflightStatus != nil || finalization.stoppedNormally) && helperPID == nil) else { return }
        if verifiedExitRecord != nil && (!orderlyFinished || expected == nil) {
            finishVerification(success: false, waitingForDisplays: false)
            return
        }
        verificationInProgress = true
        let directory = self.directory
        let expectation = self.expected
        let request = finalization.request
        let run = workerRun
        let boundRecord = verifiedExitRecord
        let verifier = restorationVerifier
        let requiresGuardProof = !recoveryOnly || boundRecord != nil
        DispatchQueue.global().async { [weak self] in
            let result = Result { try verifier(directory, expectation, requiresGuardProof, boundRecord) }
            let waiting: Bool
            if case .failure(let error) = result { waiting = Self.waitsForDisplays(error, expectation: expectation) }
            else { waiting = false }
            Self.onMainRunLoop { [weak self] in
                guard let self, self.workerRun == run else { return }
                self.verificationInProgress = false
                guard request == self.finalization.request else { self.verifyIfFinished(); return }
                switch result {
                case .success(let record):
                    if let record, self.faultedQuitCandidate, self.finalization.faulted,
                       self.faultedStopReceived, self.workerSucceeded, !self.transportFailed,
                       self.verifiedExitRecord == nil, self.quitIsCurrent(request) {
                        guard self.persistFailureForExit?() == true, self.quitIsCurrent(request) else {
                            self.finishVerification(success: false, waitingForDisplays: false)
                            return
                        }
                        self.retireWorkerHandles()
                        self.verifiedExitRecord = record
                        self.faultedQuitCandidate = false
                        self.recoveryOnly = true
                        print("原会话与辅助已退出；开始本次退出唯一的只读终验。")
                        self.launch(.verifyRestored(record))
                        return
                    }
                    var success = self.workerSucceeded && !self.transportFailed && !self.finalization.faulted
                    if self.quitting {
                        do { try self.finalizeRecord(record, request: request) }
                        catch { success = false }
                    }
                    self.finishVerification(success: success, waitingForDisplays: false)
                case .failure:
                    self.finishVerification(success: false, waitingForDisplays: waiting)
                }
            }
        }
    }

    private func quitIsCurrent(_ request: UUID?) -> Bool {
        guard quitting, let request, request == finalization.request,
              let quitDeadline, let current = try? now() else { return false }
        return current < quitDeadline
    }

    private func finalizeRecord(_ record: RecoveryRecord?, request: UUID?) throws {
        guard quitIsCurrent(request), finalization.permitsClear(request: request, recoveryOnly: recoveryOnly,
                                        workerSucceeded: workerSucceeded, transportFailed: transportFailed) else {
            throw RecoveryError.unfinishedTransaction
        }
        if let verifiedExitRecord {
            guard record == verifiedExitRecord, orderlyFinished,
                  persistFailureForExit?() == true, quitIsCurrent(request) else {
                throw RecoveryError.unfinishedTransaction
            }
        }
        let store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
        guard try store.load() == record, quitIsCurrent(request) else { throw RecoveryError.unfinishedTransaction }
        if record != nil { try store.clear() }
        if verifiedExitRecord != nil { print("故障门禁保持；只读终验完成，允许结束本次退出。") }
    }

    private nonisolated static func waitsForDisplays(
        _ error: Error,
        expectation: InternalApplicationExpectation?
    ) -> Bool {
        guard let expectation,
              let snapshot = try? freshSnapshot(),
              let current = try? snapshot.layout() else { return false }
        let baseline = expectation.baseline
        return !Set(baseline.origins.keys).isSubset(of: Set(current.origins.keys))
    }

    private func retireWorkerHandles() {
        workerPID = nil
        helperPID = nil
        workerSource?.cancel()
        workerSource = nil
        helperSource?.cancel()
        helperSource = nil
        channelSource?.cancel()
        channelSource = nil
        channel = nil
    }

    private func finishVerification(success: Bool, waitingForDisplays: Bool) {
        retireWorkerHandles()
        if quitting {
            finishQuit(success: success, status: waitingForDisplays ? .quitWaitingForDisplays : .quitFailed)
        } else if success {
            if let preflight = internalApplicationVerifiedPreflightStatus(
                preflightStatus,
                initialRecordExisted: initialRecordExisted,
                recordIsAbsent: true,
                expectationIsAbsent: expected == nil,
                helperStarted: helperPID != nil,
                workerExited: workerExited,
                channelDrained: channelDrained
            ) {
                publish(preflight)
            } else {
                publish(.applicationFailedRestored)
            }
        } else {
            publish(.recoveryIncomplete)
        }
        expected = nil
        verifiedExitRecord = nil
        preflightStatus = nil
        recoveryOnly = false
        workerExited = false
        helperExited = false
    }

    private func finishQuit(success: Bool, status: PrimarySessionStatus) {
        let success = success && quitIsCurrent(finalization.request)
        quitWatchdog?.cancel()
        quitWatchdog = nil
        let completion = quitCompletion
        quitCompletion = nil
        quitting = false
        faultedQuitCandidate = false
        finalization.cancelQuit()
        if !success { publish(status) }
        guard let completion else { return }
        Self.onMainRunLoop { completion(success) }
    }

    private func send(_ command: InternalApplicationCommand) {
        guard let channel, let pid = workerPID else {
            if quitting { finishQuit(success: false, status: .quitFailed) }
            else { publish(.recoveryIncomplete) }
            return
        }
        let run = workerRun
        let deadline = quitDeadline
        let readClock = now
        DispatchQueue.global().async { [weak self] in
            do {
                if case .verifyRestored = command {
                    guard let deadline, try readClock() < deadline else { throw GuardError.suspended }
                }
                try channel.send(command)
            }
            catch {
                Self.onMainRunLoop { [weak self] in
                    guard let self, self.workerRun == run else { return }
                    self.channelDidFail(from: pid)
                }
            }
        }
    }

    private func publish(_ status: PrimarySessionStatus) {
        statusHandler?(status)
    }

    private nonisolated static func onMainRunLoop(
        _ action: @escaping @MainActor @Sendable () -> Void
    ) {
        RunLoop.main.perform(inModes: [.common, .modalPanel]) {
            MainActor.assumeIsolated { action() }
        }
    }
}
