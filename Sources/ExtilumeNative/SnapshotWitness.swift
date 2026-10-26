import Darwin
import ExtilumeCore
import Foundation

enum SnapshotWitnessError: Error, Equatable {
    case spawnFailed
    case communicationFailed
    case timedOut
    case invalidSnapshot
    case snapshotUnavailable
    case processFailed
    case cleanupFailed
    case internalStateChanged
    case internalInformationUnavailable
    case externalStateChanged
}

func freshSnapshot() throws -> Snapshot {
    try freshWitness(Snapshot.self, arguments: ["--display-snapshot"], validate: isValid)
}

func freshActiveSnapshot() throws -> Snapshot {
    try freshWitness(Snapshot.self, arguments: ["--active-display-snapshot"], validate: isValid)
}

private struct InternalDisplayRequest: Codable {
    let identity: UUID
    let numericIDHint: UInt32
    let hardwareIdentity: InternalDisplayHardwareIdentity?
}

enum InternalDisplayReply: Codable {
    case state(InternalDisplayState)
    case stateChanged
    case internalInformationUnavailable

    func get() throws -> InternalDisplayState {
        switch self {
        case .state(let state): return state
        case .stateChanged: throw SnapshotWitnessError.internalStateChanged
        case .internalInformationUnavailable: throw SnapshotWitnessError.internalInformationUnavailable
        }
    }
}

func freshInternalDisplay(
    identity: UUID, numericIDHint: UInt32,
    hardwareIdentity: InternalDisplayHardwareIdentity? = nil,
    diagnosticRole: InternalLifecycleRole = .controller,
    trace: ((InternalLifecycleStage) -> Void)? = nil,
    deadlineNanoseconds: UInt64? = nil,
    checkAccess: (() throws -> Void)? = nil,
    spawn: ([String], GuardChannel) throws -> pid_t = spawnProbe
) throws -> InternalDisplayState {
    guard numericIDHint != 0 else { throw SnapshotWitnessError.invalidSnapshot }
    let trace = trace ?? { traceInternalLifecycle($0, role: diagnosticRole) }
    let request = InternalDisplayRequest(identity: identity, numericIDHint: numericIDHint, hardwareIdentity: hardwareIdentity)
    do {
        let reply = try freshWitness(
            InternalDisplayReply.self, arguments: ["--internal-display-snapshot"], spawn: spawn,
            deadlineNanoseconds: deadlineNanoseconds, checkAccess: checkAccess,
            prepare: { channel, check in
                try channel.send(request, deadlineNanoseconds: deadlineNanoseconds, checkAccess: check)
            }, trace: trace,
            validate: {
                switch $0 {
                case .state(let state):
                    return state.matches(identity: identity, hardwareIdentity: hardwareIdentity)
                case .stateChanged:
                    return true
                case .internalInformationUnavailable:
                    return hasValidHardwareIdentity(hardwareIdentity)
                }
            }
        )
        // 先核验并回收子进程，不能让状态变化掩盖异常退出或清理失败。
        return try reply.get()
    } catch {
        fputs("内屏独立观测失败，类别=\(snapshotWitnessFailureCode(error))；保留恢复责任。\n", stderr)
        throw error
    }
}

private struct ExternalDisplayRequest: Codable {
    let identity: ExternalDisplayIdentity
    let numericIDHint: UInt32
}

enum ExternalDisplayReply: Codable {
    case state(ExternalDisplayState)
    case stateChanged

    func get() throws -> ExternalDisplayState {
        switch self {
        case .state(let state): return state
        case .stateChanged: throw SnapshotWitnessError.externalStateChanged
        }
    }
}

func freshExternalDisplay(
    identity: ExternalDisplayIdentity,
    numericIDHint: UInt32,
    deadlineNanoseconds: UInt64? = nil,
    checkAccess: (() throws -> Void)? = nil,
    spawn: ([String], GuardChannel) throws -> pid_t = spawnProbe
) throws -> ExternalDisplayState {
    guard numericIDHint != 0 else { throw SnapshotWitnessError.invalidSnapshot }
    do { try identity.validate() }
    catch { throw SnapshotWitnessError.invalidSnapshot }
    let request = ExternalDisplayRequest(identity: identity, numericIDHint: numericIDHint)
    do {
        let reply = try freshWitness(
            ExternalDisplayReply.self, arguments: ["--external-display-snapshot"], spawn: spawn,
            deadlineNanoseconds: deadlineNanoseconds, checkAccess: checkAccess,
            prepare: { channel, check in
                try channel.send(request, deadlineNanoseconds: deadlineNanoseconds, checkAccess: check)
            },
            validate: {
                switch $0 {
                case .state(let state): return state.matches(identity: identity)
                case .stateChanged: return true
                }
            }
        )
        return try reply.get()
    } catch {
        fputs("外屏独立观测失败，类别=\(snapshotWitnessFailureCode(error))；保留恢复责任。\n", stderr)
        throw error
    }
}

func serveExternalDisplay(
    descriptor: Int32,
    reader: (ExternalDisplayIdentity, UInt32) throws -> ExternalDisplayState = {
        try readExternalDisplay(identity: $0, numericIDHint: $1)
    }
) throws {
    let channel: GuardChannel
    do { channel = try GuardChannel(descriptor: descriptor) }
    catch {
        Darwin.close(descriptor)
        throw SnapshotWitnessError.communicationFailed
    }
    let request = try channel.receive(ExternalDisplayRequest.self)
    guard request.numericIDHint != 0 else { throw SnapshotWitnessError.invalidSnapshot }
    do { try request.identity.validate() }
    catch { throw SnapshotWitnessError.invalidSnapshot }
    let before = try reader(request.identity, request.numericIDHint)
    guard before.matches(identity: request.identity) else { throw SnapshotWitnessError.invalidSnapshot }
    let after = try reader(request.identity, request.numericIDHint)
    guard after.matches(identity: request.identity) else { throw SnapshotWitnessError.invalidSnapshot }
    try channel.send(before == after ? ExternalDisplayReply.state(after) : .stateChanged)
}

func freshWitness<Value: Decodable>(
    _ type: Value.Type,
    arguments: [String],
    spawn: ([String], GuardChannel) throws -> pid_t = spawnProbe,
    deadlineNanoseconds: UInt64? = nil,
    checkAccess: (() throws -> Void)? = nil,
    prepare: (GuardChannel, (() throws -> Void)?) throws -> Void = { _, _ in },
    trace: (InternalLifecycleStage) -> Void = { _ in },
    validate: (Value) -> Bool
) throws -> Value {
    var accessError: Error?
    let checkedAccess: (() throws -> Void)? = checkAccess.map { check in
        {
            do { try check() }
            catch { accessError = error; throw error }
        }
    }
    func checkWait() throws {
        try checkedAccess?()
        if let deadlineNanoseconds {
            guard try ContinuousClock.nanoseconds() < deadlineNanoseconds else {
                throw SnapshotWitnessError.timedOut
            }
        }
    }
    try checkWait()
    trace(.witnessSpawnStarted)
    let parentChannel: GuardChannel
    var childChannel: GuardChannel?
    do {
        let pair = try GuardChannel.pair()
        parentChannel = pair.0
        childChannel = pair.1
    } catch {
        trace(.witnessFailed)
        throw SnapshotWitnessError.communicationFailed
    }

    let witness: pid_t
    do {
        guard let childChannel else { throw SnapshotWitnessError.spawnFailed }
        witness = try spawn(arguments, childChannel)
    } catch {
        childChannel = nil
        trace(.witnessFailed)
        throw SnapshotWitnessError.spawnFailed
    }
    childChannel = nil
    trace(.witnessSpawnFinished)

    var reaped = false
    do {
        try checkWait()
        let snapshot: Value
        do {
            trace(.witnessRequestStarted)
            try prepare(parentChannel, checkedAccess)
            try checkWait()
            trace(.witnessRequestFinished)
            trace(.witnessReplyStarted)
            snapshot = try parentChannel.receive(type, deadlineNanoseconds: deadlineNanoseconds, checkAccess: checkedAccess)
            trace(.witnessReplyFinished)
        } catch let error as GuardChannelError where error == .timedOut {
            throw SnapshotWitnessError.timedOut
        } catch let error as SnapshotWitnessError where error == .timedOut {
            throw error
        } catch {
            throw SnapshotWitnessError.communicationFailed
        }

        try checkWait()
        guard validate(snapshot) else { throw SnapshotWitnessError.invalidSnapshot }
        trace(.witnessExitStarted)
        guard let status = try waitForExit(witness, polls: 100,
                                         deadlineNanoseconds: deadlineNanoseconds, checkAccess: checkedAccess) else {
            throw SnapshotWitnessError.timedOut
        }
        reaped = true
        try checkWait()
        trace(.witnessExitFinished)
        guard status == 0 else { // Darwin wait 状态只有正常 exit(0) 为零；Swift 不导入 wait 宏。
            throw SnapshotWitnessError.processFailed
        }
        return snapshot
    } catch {
        trace(.witnessFailed)
        if !reaped {
            trace(.witnessCleanupStarted)
            guard terminateAndReap(witness) else { throw SnapshotWitnessError.cleanupFailed }
            reaped = true
            trace(.witnessCleanupFinished)
        }
        if let accessError { throw accessError }
        throw sanitized(error)
    }
}

func serveInternalDisplay(
    descriptor: Int32,
    reader: (UUID, UInt32, InternalDisplayHardwareIdentity?) throws -> InternalDisplayState = {
        try readInternalDisplay(identity: $0, numericIDHint: $1, hardwareIdentity: $2)
    }
) throws {
    let channel: GuardChannel
    do { channel = try GuardChannel(descriptor: descriptor) }
    catch {
        Darwin.close(descriptor)
        throw SnapshotWitnessError.communicationFailed
    }
    let request = try channel.receive(InternalDisplayRequest.self)
    traceInternalLifecycle(.witnessRequestReceived, role: .witness)
    guard request.numericIDHint != 0 else { throw SnapshotWitnessError.invalidSnapshot }
    do {
        traceInternalLifecycle(.witnessReadStarted, role: .witness)
        let before = try reader(request.identity, request.numericIDHint, request.hardwareIdentity)
        traceInternalLifecycle(.witnessReadFinished, role: .witness)
        guard before.matches(identity: request.identity, hardwareIdentity: request.hardwareIdentity) else {
            throw SnapshotWitnessError.invalidSnapshot
        }
        traceInternalLifecycle(.witnessReadStarted, role: .witness)
        let after = try reader(request.identity, request.numericIDHint, request.hardwareIdentity)
        traceInternalLifecycle(.witnessReadFinished, role: .witness)
        guard after.matches(identity: request.identity, hardwareIdentity: request.hardwareIdentity) else {
            throw SnapshotWitnessError.invalidSnapshot
        }
        try channel.send(before == after ? InternalDisplayReply.state(after) : .stateChanged)
    } catch SnapshotWitnessError.internalInformationUnavailable {
        guard hasValidHardwareIdentity(request.hardwareIdentity) else {
            throw SnapshotWitnessError.invalidSnapshot
        }
        try channel.send(InternalDisplayReply.internalInformationUnavailable)
    }
}

private func hasValidHardwareIdentity(_ hardwareIdentity: InternalDisplayHardwareIdentity?) -> Bool {
    guard let hardwareIdentity else { return false }
    do { try hardwareIdentity.validate(); return true }
    catch { return false }
}

func serveSnapshot(descriptor: Int32, activeOnly: Bool = false) throws {
    let channel: GuardChannel
    do {
        channel = try GuardChannel(descriptor: descriptor)
    } catch {
        Darwin.close(descriptor)
        throw SnapshotWitnessError.communicationFailed
    }

    let snapshot: Snapshot
    do {
        snapshot = try stableSnapshot(activeOnly: activeOnly)
    } catch {
        throw SnapshotWitnessError.snapshotUnavailable
    }

    do {
        try channel.send(snapshot)
    } catch {
        throw SnapshotWitnessError.communicationFailed
    }
}

private func isValid(_ snapshot: Snapshot) -> Bool {
    let identifiers = snapshot.displays.map(\.id)
    return !identifiers.isEmpty
        && identifiers.count <= 16
        && identifiers.allSatisfy { $0 != 0 }
        && Set(identifiers).count == identifiers.count
}

private func waitForExit(
    _ process: pid_t, polls: Int, deadlineNanoseconds: UInt64? = nil,
    checkAccess: (() throws -> Void)? = nil
) throws -> Int32? {
    for _ in 0..<polls {
        try checkAccess?()
        if let deadlineNanoseconds {
            guard try ContinuousClock.nanoseconds() < deadlineNanoseconds else {
                throw SnapshotWitnessError.timedOut
            }
        }
        var status: Int32 = 0
        let result = waitpid(process, &status, WNOHANG)
        if result == process { return status }
        if result == 0 {
            Thread.sleep(forTimeInterval: 0.01)
            continue
        }
        if result == -1 && errno == EINTR { continue }
        throw SnapshotWitnessError.processFailed
    }
    return nil
}

private func terminateAndReap(_ process: pid_t) -> Bool {
    do {
        if try waitForExit(process, polls: 1) != nil { return true }
        _ = kill(process, SIGTERM)
        if try waitForExit(process, polls: 20) != nil { return true }
        _ = kill(process, SIGKILL)
        return try waitForExit(process, polls: 100) != nil
    } catch {
        return false
    }
}

private func sanitized(_ error: Error) -> SnapshotWitnessError {
    error as? SnapshotWitnessError ?? .communicationFailed
}
