import CoreFoundation
import Darwin
import ExtilumeCore
import Foundation

func internalApplicationTargetLayout(
    for confirmedC: DisplayLayout,
    externalIdentity: UUID
) throws -> DisplayLayout {
    try layoutByMakingMain(confirmedC, target: externalIdentity)
}

enum InternalApplicationPreflightError: Error {
    case noExternalDisplay
    case lidClosed
    case unsupportedTopology
}

func internalApplicationPreflightStatus(
    error: Error,
    initialRecordExisted: Bool,
    recordIsAbsent: Bool,
    helperStarted: Bool
) -> PrimarySessionStatus? {
    guard !initialRecordExisted, recordIsAbsent, !helperStarted else { return nil }
    switch error as? InternalApplicationPreflightError {
    case .some(.noExternalDisplay), .some(.lidClosed):
        return .waiting
    case .some(.unsupportedTopology):
        return .unsupported("仅支持开盖、未镜像的内屏和一个物理外屏")
    case nil:
        if error as? DisplayEnableTransactionError == .symbolUnavailable {
            return .unsupported("当前系统缺少内屏停用能力")
        }
        return nil
    }
}

func internalApplicationVerifiedPreflightStatus(
    _ status: PrimarySessionStatus?,
    initialRecordExisted: Bool,
    recordIsAbsent: Bool,
    expectationIsAbsent: Bool,
    helperStarted: Bool,
    workerExited: Bool,
    channelDrained: Bool
) -> PrimarySessionStatus? {
    guard let status, !initialRecordExisted, recordIsAbsent, expectationIsAbsent,
          !helperStarted, workerExited, channelDrained else { return nil }
    switch status {
    case .waiting, .unsupported(_): return status
    default: return nil
    }
}

struct InternalApplicationExpectation: Codable, Equatable, Sendable {
    let session: UUID
    let generation: UInt64
    let baseline: DisplayLayout
    let internalIdentity: UUID
    let numericIDHint: UInt32?
    let hardware: InternalDisplayHardwareIdentity?

    init(record: RecoveryRecord) throws {
        guard let responsibility = record.internalDisplay, responsibility.baseline else { throw RecoveryError.invalidRecord }
        session = record.session
        generation = record.generation
        baseline = record.baseline
        internalIdentity = responsibility.identity
        numericIDHint = responsibility.numericIDHint
        hardware = responsibility.hardwareIdentity
        try validate()
    }

    func validate() throws {
        guard generation > 0, session != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
              baseline.origins.count == 2, baseline.origins[internalIdentity] != nil,
              baseline.origins[baseline.main] == DisplayOrigin(x: 0, y: 0),
              let numericIDHint, numericIDHint != 0, let hardware else { throw RecoveryError.invalidRecord }
        try hardware.validate()
    }

    func matchesRestoredRecord(_ record: RecoveryRecord) -> Bool {
        guard (try? record.validate()) != nil, record.canClear,
              record.session == session, record.generation == generation,
              record.baseline == baseline, let responsibility = record.internalDisplay else { return false }
        return responsibility.identity == internalIdentity && responsibility.baseline && !responsibility.pending
            && responsibility.hardwareIdentity == hardware
    }
}

enum InternalApplicationCommand: Codable, Equatable, Sendable {
    case start(recoveryOnly: Bool)
    case verifyRestored(RecoveryRecord)
    case stop
    case restore
    case confirmUser
    case reapply
}

func internalApplicationCommandForPendingQuit(
    _ command: InternalApplicationCommand,
    quitting: Bool
) -> InternalApplicationCommand {
    if case .verifyRestored = command { return command }
    return quitting ? .start(recoveryOnly: true) : command
}

struct InternalApplicationHandshakeRequest: Codable, Sendable {
    let challenge: UUID
    let parentPID: Int32
    let parentUID: UInt32
    var version = 1
}

struct InternalApplicationHandshakeReply: Codable, Sendable {
    let challenge: UUID
    let workerPID: Int32
    let workerUID: UInt32
    var version = 1
}

enum InternalApplicationEvent: Codable, Sendable {
    case ready(InternalApplicationHandshakeReply)
    case helperStarted(Int32)
    case expectation(InternalApplicationExpectation)
    case status(PrimarySessionStatus)
    case finished
    case failed
    case faulted
    case stopped(faulted: Bool)
}

struct InternalApplicationGuardCallbacks: Sendable {
    let status: @Sendable (PrimarySessionStatus) -> Void
    let helperStarted: @Sendable (Int32) -> Void
    let expectation: @Sendable (InternalApplicationExpectation) -> Void
    let checkAccess: @Sendable () throws -> Void
    let faulted: @Sendable () -> Void
    let stopped: @Sendable (Bool) -> Void
}

final class InternalApplicationWorkerState: @unchecked Sendable {
    let channel: GuardChannel
    private var storedSession: GuardSession?
    var started = false
    private let helperLock = NSLock()
    private var helperStarted = false
    private var channelLost = false
    private var stopRequested = false
    private var recoveryRunning = false
    private let onFinish: @Sendable () -> Void

    var session: GuardSession? {
        get { helperLock.withLock { storedSession } }
        set { helperLock.withLock { storedSession = newValue } }
    }

    var hasLostChannel: Bool { helperLock.withLock { channelLost } }
    var isStopping: Bool { helperLock.withLock { stopRequested } }
    func beginRecovery() { helperLock.withLock { recoveryRunning = true } }

    func requestStop() {
        helperLock.withLock { stopRequested = true }
        if let session { session.receiveApplicationCommand(.stop) }
        else if !helperLock.withLock({ recoveryRunning }) {
            send(.stopped(faulted: hasLostChannel))
            finish()
        }
    }

    init(channel: GuardChannel, onFinish: @escaping @Sendable () -> Void = {
        RunLoop.main.perform(inModes: [.common]) { CFRunLoopStop(CFRunLoopGetMain()) }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }) {
        self.channel = channel
        self.onFinish = onFinish
    }

    func checkAccess(parentPID: Int32) throws {
        guard !hasLostChannel, getppid() == parentPID, try !channel.peerClosed() else {
            throw GuardError.protectionLost
        }
        if isStopping { throw InternalControlCancellation.pauseRequested }
    }

    func send(_ event: InternalApplicationEvent) {
        do { try channel.send(event) }
        catch { loseChannel() }
    }

    func loseChannel() {
        let first = helperLock.withLock {
            if channelLost { return false }
            channelLost = true
            return true
        }
        guard first else { return }
        if let session { session.applicationChannelLost() }
        else if !helperLock.withLock({ recoveryRunning }) { finish() }
    }

    func finish() {
        onFinish()
    }

    func noteHelperStarted() {
        helperLock.lock()
        helperStarted = true
        helperLock.unlock()
    }

    var hasStartedHelper: Bool {
        helperLock.lock()
        defer { helperLock.unlock() }
        return helperStarted
    }
}

/// Handles only the private child-process branch. Normal application arguments cause no I/O.
public func runInternalApplicationWorkerIfRequested() -> Bool {
    let arguments = CommandLine.arguments
    guard arguments.count == 5, arguments[1] == "--internal-app-session" else { return false }

    guard let parentPID = pid_t(arguments[3]), parentPID > 1,
          let descriptor = Int32(arguments[4]), descriptor == 198,
          !arguments[2].isEmpty else {
        fputs("内部会话 worker 参数无效。\n", stderr)
        exit(EXIT_FAILURE)
    }

    do {
        let channel = try GuardChannel(descriptor: descriptor)
        let request = try channel.receive(InternalApplicationHandshakeRequest.self)
        guard request.parentPID == parentPID, request.parentPID == getppid(),
              request.parentUID == UInt32(getuid()), request.version == 1, kill(parentPID, 0) == 0 else {
            throw GuardError.identity
        }
        let state = InternalApplicationWorkerState(channel: channel)
        state.send(.ready(InternalApplicationHandshakeReply(
            challenge: request.challenge, workerPID: getpid(), workerUID: UInt32(getuid())
        )))

        let callbacks = InternalApplicationGuardCallbacks(
            status: { state.send(.status($0)) },
            helperStarted: { pid in
                state.noteHelperStarted()
                state.send(.helperStarted(pid))
            },
            expectation: { state.send(.expectation($0)) },
            checkAccess: {
                try state.checkAccess(parentPID: parentPID)
            },
            faulted: { state.send(.faulted) },
            stopped: { state.send(.stopped(faulted: $0)) }
        )
        let parent = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .global())
        parent.setEventHandler { state.loseChannel() }
        parent.resume()
        let queue = DispatchQueue(label: "Extilume.internal-app-worker")
        let sessionQueue = DispatchQueue(label: "Extilume.internal-app-session")
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [state] in
            do {
                let command = try channel.receive(InternalApplicationCommand.self)
                guard !state.hasLostChannel, getppid() == parentPID, try !channel.peerClosed() else {
                    throw GuardError.protectionLost
                }
                switch command {
                case .verifyRestored(let record):
                    guard !state.started else { throw GuardError.protectionLost }
                    state.started = true
                    state.beginRecovery()
                    sessionQueue.async {
                        do {
                            let expectation = try InternalApplicationExpectation(record: record)
                            _ = try verifyInternalApplicationRestoration(
                                directory: URL(fileURLWithPath: arguments[2], isDirectory: true),
                                expectation: expectation, requiresGuardProof: true, expectedRecord: record
                            )
                            state.send(.expectation(expectation))
                            state.send(.finished)
                        } catch {
                            state.send(.failed)
                        }
                        state.finish()
                    }
                case .start(let recoveryOnly):
                    guard !state.started else {
                        state.send(.status(.recoveryIncomplete))
                        return
                    }
                    state.started = true
                    if recoveryOnly { state.beginRecovery() }
                    sessionQueue.async {
                        if recoveryOnly {
                            do {
                                let store = try RecoveryStore(directory: URL(fileURLWithPath: arguments[2], isDirectory: true))
                                if let record = try store.load() {
                                    state.send(.expectation(try InternalApplicationExpectation(record: record)))
                                    try recoverInternalRecord(directory: URL(fileURLWithPath: arguments[2], isDirectory: true))
                                }
                                state.send(.status(.applicationFailedRestored))
                                state.send(.finished)
                                state.finish()
                            } catch {
                                state.send(.status(.recoveryIncomplete))
                                state.send(.failed)
                                state.finish()
                            }
                        } else {
                            guard !state.hasLostChannel, !state.isStopping else { state.finish(); return }
                            state.send(.status(.applying))
                            let directory = URL(fileURLWithPath: arguments[2], isDirectory: true)
                            var initialRecordExisted = false
                            do {
                                let store = try RecoveryStore(directory: directory)
                                initialRecordExisted = try store.load() != nil
                                guard !initialRecordExisted else { throw RecoveryError.unfinishedTransaction }
                                let session = try GuardSession(
                                    directory: directory,
                                    operation: .disableInternal,
                                    applicationCallbacks: callbacks
                                )
                                state.session = session
                                guard !state.hasLostChannel, !state.isStopping else {
                                    state.send(.stopped(faulted: state.hasLostChannel))
                                    state.finish()
                                    return
                                }
                                try session.start()
                            } catch {
                                let recordIsAbsent: Bool
                                do {
                                    recordIsAbsent = try RecoveryStore(directory: directory).load() == nil
                                } catch {
                                    recordIsAbsent = false
                                }
                                if let status = internalApplicationPreflightStatus(
                                    error: error,
                                    initialRecordExisted: initialRecordExisted,
                                    recordIsAbsent: recordIsAbsent,
                                    helperStarted: state.hasStartedHelper
                                ) {
                                    state.send(.status(status))
                                    state.send(.finished)
                                } else {
                                    state.send(.status(.recoveryIncomplete))
                                    state.send(.failed)
                                }
                                state.finish()
                            }
                        }
                    }
                case .stop:
                    state.requestStop()
                case .restore:
                    state.session?.receiveApplicationCommand(.restore)
                case .confirmUser:
                    state.session?.receiveApplicationCommand(.confirmUser)
                case .reapply:
                    state.session?.receiveApplicationCommand(.reapply)
                }
            } catch {
                if let session = state.session {
                    session.applicationChannelLost()
                } else {
                    state.send(.failed)
                    state.finish()
                }
            }
        }
        source.resume()
        let keepAlive = NSMachPort()
        RunLoop.main.add(keepAlive, forMode: .default)
        CFRunLoopRun()
        source.cancel()
        parent.cancel()
        keepAlive.invalidate()
        withExtendedLifetime((source, parent, state, keepAlive)) {}
        return true
    } catch {
        fputs("内部会话 worker 身份核验失败。\n", stderr)
        exit(EXIT_FAILURE)
    }
}
