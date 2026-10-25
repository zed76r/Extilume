import CoreGraphics
import Darwin
import ExtilumeCore
import Foundation

private struct GuardReply: Codable { let ready: ProtectionHandshake; var powerReady: Bool? = nil }
private enum GuardCommand: String, Codable { case quiesce }
enum GuardError: Error, Equatable { case spawn, identity, missingRecord, protectionLost, suspended, unstable }

func validateInternalGuardReadiness(
    snapshot: Snapshot, record: RecoveryRecord,
    internalState: InternalDisplayState, lidOpen: Bool
) throws {
    try record.validate()
    guard record.phase == .applying, !record.sourceUnresolved,
          let responsibility = record.internalDisplay, responsibility.baseline else { throw GuardError.missingRecord }
    let builtIn = try snapshot.builtInDisplay(identity: responsibility.identity)
    guard snapshot.assessment.isSupported, snapshot.displays.count == 2, lidOpen,
          let external = snapshot.displays.first(where: { $0.identity == .physical })?.identityUUID,
          builtIn.isActive && builtIn.isOnline,
          internalState.matches(identity: responsibility.identity, hardwareIdentity: responsibility.hardwareIdentity),
          internalState.isEnabled, internalState.id == builtIn.id else {
        throw GuardError.protectionLost
    }
    // 保护先接管当前 C；外屏主屏平移必须等保护就绪后再提交。
    guard try snapshot.layout() == record.baseline,
          record.applied == (try layoutByMakingMain(record.baseline, target: external)) else {
        throw GuardError.protectionLost
    }
}

func internalWakeVerificationRetryDelay(error: Error, attempt: Int, lifecycle: InternalSessionLifecycle) -> TimeInterval? {
    guard error as? GuardError == .unstable || error as? SnapshotWitnessError == .internalStateChanged,
          attempt < 2, lifecycle.shouldRecoverAfterWake, !lifecycle.faulted, !lifecycle.stopRequested else { return nil }
    return 0.3
}

private let internalWakeRecoveryBudgetNanoseconds: UInt64 = 10_000_000_000

func internalWakeWitnessDeadline(now: UInt64, elapsed: UInt64?) -> UInt64? {
    guard let elapsed, elapsed < internalWakeRecoveryBudgetNanoseconds else { return nil }
    let (deadline, overflow) = now.addingReportingOverflow(internalWakeRecoveryBudgetNanoseconds - elapsed)
    return overflow ? nil : deadline
}

func internalWakeInformationRetryDelay(
    error: Error, elapsed: UInt64?, lifecycle: InternalSessionLifecycle
) -> TimeInterval? {
    guard error as? SnapshotWitnessError == .internalInformationUnavailable,
          lifecycle.shouldRecoverAfterWake, lifecycle.resumeAfterWake,
          !lifecycle.faulted, !lifecycle.stopRequested,
          let elapsed, elapsed < internalWakeRecoveryBudgetNanoseconds else { return nil }
    return min(0.3, Double(internalWakeRecoveryBudgetNanoseconds - elapsed) / 1_000_000_000)
}

enum InternalWakeRecoveryDeadlineDecision: Equatable {
    case stale
    case wait(TimeInterval)
    case expired
}

func internalWakeRecoveryDeadlineDecision(
    epoch: UUID, lifecycle: inout InternalSessionLifecycle, elapsed: UInt64?
) -> InternalWakeRecoveryDeadlineDecision {
    guard lifecycle.sleepEpoch == epoch, lifecycle.wakeRecoveryRequired, !lifecycle.sleeping,
          !lifecycle.faulted, !lifecycle.stopRequested else { return .stale }
    guard let elapsed, elapsed < internalWakeRecoveryBudgetNanoseconds else {
        lifecycle.fail()
        return .expired
    }
    return .wait(Double(internalWakeRecoveryBudgetNanoseconds - elapsed) / 1_000_000_000)
}

func spawnProbe(_ arguments: [String], channel: GuardChannel) throws -> pid_t {
    let inheritedDescriptor: Int32 = 198
    var actions: posix_spawn_file_actions_t?
    guard posix_spawn_file_actions_init(&actions) == 0 else { throw GuardError.spawn }
    defer { posix_spawn_file_actions_destroy(&actions) }
    for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
        guard posix_spawn_file_actions_addinherit_np(&actions, descriptor) == 0 else { throw GuardError.spawn }
    }
    guard posix_spawn_file_actions_adddup2(&actions, channel.descriptor, inheritedDescriptor) == 0 else {
        throw GuardError.spawn
    }
    var attributes: posix_spawnattr_t?
    guard posix_spawnattr_init(&attributes) == 0 else { throw GuardError.spawn }
    defer { posix_spawnattr_destroy(&attributes) }
    // 主进程的控制终端关闭时，保护与独立观测不能随原会话收到挂断信号。
    guard posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID)) == 0 else {
        throw GuardError.spawn
    }
    let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
    let strings = ([executable] + arguments + [String(inheritedDescriptor)]).map { strdup($0)! }
    defer { strings.forEach { free($0) } }
    var arguments: [UnsafeMutablePointer<CChar>?] = strings.map { $0 } + [nil]
    var child: pid_t = 0
    let result = arguments.withUnsafeMutableBufferPointer {
        posix_spawn(&child, executable, &actions, &attributes, $0.baseAddress!, environ)
    }
    guard result == 0, child > 1 else { throw GuardError.spawn }
    return child
}

enum GuardSessionOperation { case drill, internalDrill, disableInternal }

func internalRecoveryRetryDelay(attemptCount: Int, elapsed: UInt64?) -> TimeInterval? {
    guard let elapsed, elapsed < 10_000_000_000 else { return nil }
    let backoff = min(1.0, 0.1 * pow(2.0, Double(min(attemptCount, 4))))
    return min(backoff, Double(10_000_000_000 - elapsed) / 1_000_000_000)
}

final class GuardSession: @unchecked Sendable {
    private let directory: URL
    private let store: RecoveryStore
    private let operation: GuardSessionOperation
    private let enableTransaction: DisplayEnableTransaction?
    private let queue = DispatchQueue(label: "Extilume.guard-drill")
    private let queueKey = DispatchSpecificKey<Bool>()
    private var record: RecoveryRecord?
    private var channel: GuardChannel?
    private var child: pid_t = 0
    private var deathSource: DispatchSourceProcess?
    private var protectionInputSource: DispatchSourceRead?
    private var signals: [DispatchSourceSignal] = []
    private let authorizationLock = NSLock()
    private var authorization = ProtectionAuthorization()
    private var lifecycle = InternalSessionLifecycle()
    private var connectionObserver: ConnectionObserver?
    private var connectionObserverEpoch: UUID?
    private let reapplication: PrimaryReapplicationScheduler
    private var applicationIsCurrent: (@Sendable () -> Bool)?
    private let applicationCallbacks: InternalApplicationGuardCallbacks?
    private var stopping = false
    private var internalDisplayIDHint: UInt32?
    private var powerObserver: InternalSystemPowerObserver?
    private let powerGate = InternalPowerGate()
    private var recoveryDisplayCallbackRegistered = false
    private var reportedConnectionInvalidation = false
    private var recoveryFailed = false
    private let recoveryClock = InternalRecoveryClock()
    private var recoveryRetryScheduled = false
    private var recoveryEpoch = UUID()
    private var wakePreflightEpoch: UUID?
    private var activeWakeRecoveryEpoch: UUID?

    init(
        directory: URL,
        operation: GuardSessionOperation,
        applicationCallbacks: InternalApplicationGuardCallbacks? = nil
    ) throws {
        self.directory = directory
        self.operation = operation
        self.applicationCallbacks = applicationCallbacks
        guard applicationCallbacks == nil || operation == .disableInternal else { throw GuardError.protectionLost }
        enableTransaction = operation == .disableInternal ? try DisplayEnableTransaction() : nil
        store = try RecoveryStore(directory: directory)
        reapplication = PrimaryReapplicationScheduler(ownerQueue: queue)
        try store.acquireExclusiveOwnership()
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        powerObserver?.stop()
        connectionObserver?.stopObserving()
        if recoveryDisplayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(guardSessionDisplayCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    func start() throws {
        try InternalSleepPreparation.startSession(on: queue, cleanupPower: { [self] in
            reapplication.invalidate()
            loseProtection()
            powerObserver?.stop()
        }) {
            guard try store.load() == nil else { throw RecoveryError.unfinishedTransaction }
            if operation == .disableInternal {
                guard CGDisplayRegisterReconfigurationCallback(
                    guardSessionDisplayCallback, Unmanaged.passUnretained(self).toOpaque()
                ) == .success else { throw GuardError.protectionLost }
                recoveryDisplayCallbackRegistered = true
                let observer = InternalSystemPowerObserver(
                    prepareForSleep: { [weak self] in self?.prepareForSleep() ?? false },
                    didPrepareForSleep: { [weak self] accepted, acknowledged in
                        self?.didPrepareForSleep(accepted: accepted, acknowledged: acknowledged)
                    },
                    didWake: { [weak self] in self?.didWake() },
                    onFailure: { [weak self] in
                        self?.connectionInvalidated(message: "电源通知确认失败；禁止新停用，保留恢复责任。")
                    }
                )
                try observer.start()
                powerObserver = observer
                powerGate.didRegister()
            }
            if operation == .disableInternal { try powerGate.check() }
            let snapshot = try freshSnapshot()
            let baseline = try snapshot.layout()
            let internalResponsibility: InternalDisplayResponsibility?
            var applicationExternalIdentity: UUID?
            if operation != .drill {
                let builtIns = snapshot.displays.filter { $0.identity == .builtIn }
                let physicalDisplays = snapshot.displays.filter { $0.identity == .physical }
                if applicationCallbacks != nil {
                    guard clamshellState() == "开盖" else { throw InternalApplicationPreflightError.lidClosed }
                    guard snapshot.displays.contains(where: { $0.identity != .builtIn }) else {
                        throw InternalApplicationPreflightError.noExternalDisplay
                    }
                    guard snapshot.assessment.isSupported else {
                        throw InternalApplicationPreflightError.unsupportedTopology
                    }
                    guard snapshot.displays.count == 2, builtIns.count == 1, physicalDisplays.count == 1,
                          snapshot.displays.filter(\.isMain).count == 1,
                          snapshot.displays.allSatisfy({ $0.isOnline && $0.isActive && !$0.isMirrored && $0.id != 0 && $0.identityUUID != nil }),
                          let builtIn = builtIns.first,
                          let identity = builtIn.identityUUID, builtIn.isActive && builtIn.isOnline,
                          let externalIdentity = physicalDisplays.first?.identityUUID,
                          externalIdentity != identity else { throw InternalApplicationPreflightError.unsupportedTopology }
                    applicationExternalIdentity = externalIdentity
                    let independent = try freshInternalDisplay(identity: identity, numericIDHint: builtIn.id)
                    guard independent.id == builtIn.id, independent.isEnabled,
                          let hardware = independent.hardwareIdentity else { throw GuardError.identity }
                    internalDisplayIDHint = builtIn.id
                    recoveryClock.setBootSession(hardware.bootSession)
                    internalResponsibility = InternalDisplayResponsibility(
                        identity: identity, baseline: true, applied: operation != .disableInternal,
                        hardwareIdentity: hardware, numericIDHint: builtIn.id
                    )
                } else {
                    guard clamshellState() == "开盖", snapshot.assessment.isSupported,
                          let builtIn = builtIns.first,
                          let identity = builtIn.identityUUID, builtIn.isActive && builtIn.isOnline,
                          snapshot.displays.contains(where: { $0.identity == .physical && $0.isMain }) else {
                        throw GuardError.protectionLost
                    }
                    let independent = try freshInternalDisplay(identity: identity, numericIDHint: builtIn.id)
                    guard independent.id == builtIn.id, independent.isEnabled,
                          let hardware = independent.hardwareIdentity else { throw GuardError.identity }
                    internalDisplayIDHint = builtIn.id
                    recoveryClock.setBootSession(hardware.bootSession)
                    internalResponsibility = InternalDisplayResponsibility(
                        identity: identity, baseline: true, applied: operation != .disableInternal,
                        hardwareIdentity: hardware, numericIDHint: builtIn.id
                    )
                }
            } else {
                internalResponsibility = nil
            }
            if snapshot.assessment.isSupported {
                try startConnectionObserver(responsibility: internalResponsibility)
            }
            let target: DisplayLayout
            if let applicationExternalIdentity {
                target = try internalApplicationTargetLayout(for: baseline, externalIdentity: applicationExternalIdentity)
            } else {
                target = baseline
            }
            let prepared = try RecoveryRecord(baseline: baseline, target: target, internalDisplay: internalResponsibility)
            if let applicationCallbacks {
                applicationCallbacks.expectation(try InternalApplicationExpectation(record: prepared))
            }
            try applyPrepared(prepared)
            for number in [SIGINT, SIGTERM] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { [weak self] in self?.stop() }
                signals.append(source)
                source.resume()
            }
            if !recoveryFailed && !authorizationLock.withLock({ authorization.ready }) {
                guard operation == .disableInternal else { throw GuardError.protectionLost }
                stop()
            }
            if !recoveryFailed {
                if operation == .disableInternal {
                    if authorizationLock.withLock({ lifecycle.paused }) {
                        print("会话已恢复并暂停；输入 confirm-user / reapply / stop。")
                    } else {
                        print("受保护停用已读回；尚需现场确认桌面、键盘及触控板。输入 status / restore / confirm-user / reapply / stop 恢复退出。")
                    }
                } else {
                    print("不改显示设置的保护演练已就绪；连接观察=\(connectionObserver != nil)；输入 status / stop / crash / lose-guard / invalidate-connection。")
                }
                if let applicationCallbacks {
                    let paused = authorizationLock.withLock { lifecycle.paused }
                    applicationCallbacks.status(paused ? .manualConfiguration : .applied)
                }
            }
        }
        if applicationCallbacks == nil {
            DispatchQueue.global().async { [weak self] in
                while let command = readLine() {
                    self?.command(command.trimmingCharacters(in: .whitespaces))
                }
                self?.command("stop")
            }
        }
    }

    func receiveApplicationCommand(_ command: InternalApplicationCommand) {
        switch command {
        case .start, .verifyRestored: break
        case .stop: self.command("stop")
        case .restore: self.command("restore")
        case .confirmUser: self.command("confirm-user")
        case .reapply: self.command("reapply")
        }
    }

    func applicationChannelLost() {
        loseProtection()
        command("stop")
    }

    private func applyPrepared(_ prepared: RecoveryRecord) throws {
        do {
            if operation == .disableInternal {
                if let applied = try applyProtectedInternalRecord(
                    store: store, prepared: prepared, operation: { try self.applyDurable($0) },
                    recoverOnFailure: { [self] durable, error in
                        record = durable
                        if authorizationLock.withLock({ lifecycle.pauseAfterFailure(error, protectionReady: authorization.ready) }) {
                            pauseForConfiguration(forSleep: true)
                        } else {
                            loseProtection()
                            print("停用事务未完成；主进程接管恢复，不依赖辅助进程仍存活。")
                            stop()
                        }
                    }
                ) { record = applied }
            } else {
                record = try store.apply(prepared) {
                    guard let durable = try self.store.load() else { throw GuardError.missingRecord }
                    return try self.applyDurable(durable)
                }
            }
        } catch {
            record = try store.load()
            // 已启动的辅助进程须随主进程退出继续核验。
            throw error
        }
    }

    private func applyDurable(_ durable: RecoveryRecord) throws -> (layout: DisplayLayout, internalEnabled: Bool?) {
        if operation == .disableInternal { try powerGate.check() }
        if child == 0 {
            let contract = try ProtectionHandshake(
                session: durable.session, generation: durable.generation, parentPID: getpid(),
                internalDisplayIdentity: durable.internalDisplay?.identity,
                internalDisplayHardwareIdentity: durable.internalDisplay?.hardwareIdentity
            )
            let parentChannel: GuardChannel = try {
                let pair = try GuardChannel.pair()
                child = try spawnProbe(["--display-guard", directory.path], channel: pair.1)
                applicationCallbacks?.helperStarted(child)
                return pair.0
            }()
            channel = parentChannel
            let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.loseProtection()
                self.queue.async {
                    var status: Int32 = 0
                    _ = waitpid(self.child, &status, WNOHANG)
                    if !self.stopping {
                        self.stop()
                    }
                }
                print("辅助进程失效；禁止新控制，主进程负责核验恢复。")
            }
            deathSource = source
            source.resume()
            try parentChannel.send(contract)
            let reply = try parentChannel.receive(GuardReply.self)
            if operation == .disableInternal {
                try powerGate.check()
                guard reply.powerReady == true else { throw GuardError.protectionLost }
            }
            try authorizationLock.withLock { try authorization.acknowledge(receipt: reply.ready, expected: contract) }
            let input = DispatchSource.makeReadSource(fileDescriptor: parentChannel.descriptor, queue: .global())
            input.setEventHandler { [weak self] in
                self?.protectionInputSource?.cancel()
                self?.connectionInvalidated(message: "保护通信失效；禁止新控制，主进程负责核验恢复。")
            }
            protectionInputSource = input
            input.resume()
        }
        guard let channel, try !channel.peerClosed(), kill(child, 0) == 0 else {
            loseProtection()
            throw GuardError.protectionLost
        }
        try checkProtection(durable)
        if let enableTransaction {
            guard let observer = connectionObserver else { throw GuardError.protectionLost }
            let sleepEpoch = authorizationLock.withLock { lifecycle.sleepEpoch }
            try translateProtectedInternalLayout(
                record: durable, loadRecord: { try self.store.load() },
                snapshotReader: { try self.readGuardSnapshot(durable) },
                originWriter: { origins, validate in
                    try configureOrigins(origins, option: .forAppOnly, nativeCall: { try self.powerGate.perform($0) },
                                         validateBeforeCommit: validate)
                },
                checkProtection: { try self.checkProtection($0) }
            )
            do { return try performProtectedInternalDisable(
                record: durable, loadRecord: { try self.store.load() },
                disable: { pending in
                    traceInternalLifecycle(.disableStarted, operation: .disable)
                    do {
                        try enableTransaction.disableInternal(
                            record: pending, loadRecord: { try self.store.load() },
                            snapshotReader: { try self.readGuardSnapshot(pending) }, lidIsOpen: { clamshellState() == "开盖" },
                            checkProtection: { try self.checkProtection($0) },
                            trace: { traceInternalLifecycle($0, cgError: $1, operation: .disable) },
                            nativeCall: { try self.powerGate.perform($0) },
                            completionCall: { invoke in
                                try self.powerGate.perform {
                                    try observer.performInternalDisableCommit(validateBeforeCommit: {
                                        try self.checkProtection(pending)
                                        guard self.connectionObserver === observer,
                                              self.authorizationLock.withLock({ self.lifecycle.sleepEpoch == sleepEpoch }) else {
                                            throw GuardError.protectionLost
                                        }
                                    }, invoke)
                                }
                            },
                            internalReader: { identity in
                                guard let id = self.internalDisplayIDHint else { throw GuardError.identity }
                                return try freshInternalDisplay(identity: identity, numericIDHint: id,
                                                                hardwareIdentity: pending.internalDisplay?.hardwareIdentity)
                            }
                        )
                        traceInternalLifecycle(.disableFinished, succeeded: true, operation: .disable)
                    } catch {
                        traceInternalLifecycle(.disableFailed, succeeded: false, error: error, operation: .disable)
                        throw error
                    }
                },
                activeSnapshotReader: {
                    try self.powerGate.check()
                    let snapshot = try freshActiveSnapshot()
                    try self.powerGate.check()
                    return snapshot
                },
                internalReader: { identity in
                    guard let internalDisplayIDHint else { throw GuardError.identity }
                    return try freshInternalDisplay(identity: identity, numericIDHint: internalDisplayIDHint,
                                                    hardwareIdentity: durable.internalDisplay?.hardwareIdentity)
                },
                checkProtection: { try self.checkProtection($0) },
                verifyLinkReconfiguration: {
                    guard self.connectionObserver === observer,
                          self.authorizationLock.withLock({ self.lifecycle.sleepEpoch == sleepEpoch }) else {
                        throw GuardError.protectionLost
                    }
                    try observer.verifyInternalReconfiguration()
                }
            ) } catch {
                observer.abortInternalReconfiguration()
                throw error
            }
        }
        let actual = try freshSnapshot()
        try checkProtection(durable)
        let enabled = try durable.internalDisplay.map {
            guard let internalDisplayIDHint else { throw GuardError.identity }
            return try freshInternalDisplay(identity: $0.identity, numericIDHint: internalDisplayIDHint,
                                            hardwareIdentity: $0.hardwareIdentity).isEnabled
        }
        try checkProtection(durable)
        return (try actual.layout(), enabled)
    }

    private func command(_ command: String) {
        if ["restore", "stop"].contains(command) {
            reapplication.invalidate()
        }
        if command == "stop" {
            authorizationLock.withLock {
                recoveryClock.start()
                lifecycle.requestStop()
            }
        }
        if command == "restore", operation == .disableInternal {
            authorizationLock.withLock { lifecycle.requestPause() }
        }
        if command == "invalidate-connection" {
            print("模拟连接安全条件失效；不代表实际拔线。")
            connectionInvalidated()
            return
        }
        queue.async { [weak self] in
            guard let self, !self.stopping || self.recoveryFailed else { return }
            switch command {
            case "status":
                let state = self.authorizationLock.withLock { (self.authorization.ready, self.lifecycle.paused, self.lifecycle.sleeping) }
                print("主进程仍在运行；保护就绪=\(state.0)；已暂停=\(state.1)；睡眠中=\(state.2)；连接观察=\(self.connectionObserver != nil)；责任尚未独立清除。")
            case "stop":
                self.applicationCallbacks?.status(.restoringAndQuitting)
                self.stop()
            case "restore" where self.operation == .disableInternal:
                self.pauseForConfiguration(forSleep: false)
            case "confirm-user" where self.operation == .disableInternal:
                self.reapplication.cancel()
                do {
                    try self.confirmUserConfiguration()
                    if let record = self.record {
                        self.applicationCallbacks?.expectation(try InternalApplicationExpectation(record: record))
                    }
                    self.applicationCallbacks?.status(.manualConfiguration)
                } catch {
                    self.applicationCallbacks?.status(.confirmationFailed)
                    print("用户配置未获确认；原基准及恢复责任保留。")
                }
            case "reapply" where self.operation == .disableInternal:
                self.reapplication.cancel()
                do { try self.reapply() }
                catch { print("重新应用未完成；保留当前基准及恢复责任。") }
            case "crash": _exit(99)
            case "lose-guard": _ = kill(self.child, SIGKILL)
            default: print("有效命令：status / restore / confirm-user / reapply / stop / crash / lose-guard / invalidate-connection；前三项配置命令仅用于受保护停用验证。")
            }
        }
    }

    private func checkProtection(_ record: RecoveryRecord) throws {
        do { try applicationCallbacks?.checkAccess() }
        catch let error as InternalControlCancellation { throw error }
        catch { loseProtection(); throw error }
        if operation == .disableInternal { try powerGate.check() }
        try checkProtectedPeer()
        try authorizationLock.withLock {
            guard authorization.ready && !lifecycle.faulted else { throw GuardError.protectionLost }
            guard !lifecycle.pauseRequested else { throw InternalControlCancellation.pauseRequested }
            guard lifecycle.permitsControls else { throw InternalControlCancellation.pauseRequested }
            try authorization.authorize(record: record)
        }
        guard applicationIsCurrent?() != false else { throw InternalControlCancellation.pauseRequested }
    }

    private func checkProtectedPeer() throws {
        guard let channel, try !channel.peerClosed(), kill(child, 0) == 0 else {
            loseProtection()
            throw GuardError.protectionLost
        }
        guard authorizationLock.withLock({ authorization.ready && !lifecycle.faulted }) else {
            throw GuardError.protectionLost
        }
    }

    private func loseProtection() {
        reapplication.invalidate()
        let first = authorizationLock.withLock {
            let first = !lifecycle.faulted
            recoveryClock.start()
            authorization.markLost()
            lifecycle.fail()
            return first
        }
        if first { applicationCallbacks?.faulted() }
    }

    private func connectionInvalidated(
        message: String = "连接安全条件失效；禁止新控制，主进程负责核验恢复。",
        observedAt: UInt64? = try? ContinuousClock.nanoseconds()
    ) {
        // 危险事件立即撤权，不等待控制队列上的快照或握手。
        let first = authorizationLock.withLock {
            recoveryClock.start(at: observedAt)
            let first = !reportedConnectionInvalidation
            reportedConnectionInvalidation = true
            authorization.markLost()
            lifecycle.fail()
            return first
        }
        reapplication.invalidate()
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            self.stop()
        }
        if first {
            applicationCallbacks?.faulted()
            if let observedAt { traceInternalLifecycle(.firstConnectionInvalidation, observedAt: observedAt) }
            else { print("首个连接失效计时不可用；不能据此判定恢复时限通过。") }
        }
        print(message)
    }

    private func startConnectionObserver(responsibility: InternalDisplayResponsibility?) throws {
        guard connectionObserver == nil else { throw GuardError.protectionLost }
        let epoch = UUID()
        authorizationLock.withLock { connectionObserverEpoch = epoch }
        let observer = try ConnectionObserver(
            service: matchedHDMIService(), reportsEvents: false,
            expectedDisabledInternal: operation == .disableInternal ? internalDisplayIDHint : nil,
            expectedInternalRegistryID: operation == .disableInternal ? responsibility?.hardwareIdentity?.registryEntryID : nil,
            diagnosticRole: .controller,
            onReconfiguration: { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, self.recoveryFailed,
                          self.authorizationLock.withLock({ self.connectionObserverEpoch == epoch }) else { return }
                    self.scheduleRecoveryRetry(after: 0)
                }
            }
        ) { [weak self] reason, observedAt in
            self?.connectionInvalidated(
                message: "连接安全条件失效 [\(reason)]；禁止新控制，主进程负责核验恢复。",
                observedAt: observedAt
            )
        }
        connectionObserver = observer
        try observer.start()
    }

    private func stopConnectionObserver() {
        // 先排空旧观察器；已收到的负面事件仍会锁存到当前会话。
        connectionObserver?.stopObserving()
        connectionObserver = nil
        authorizationLock.withLock { connectionObserverEpoch = nil }
    }

    fileprivate func displayChangedForRecovery() {
        // 接管观察退出后仍保留恢复事件，避免错过重试窗口后的显示重连。
        queue.async { [weak self] in
            guard let self, self.recoveryFailed else { return }
            self.scheduleRecoveryRetry(after: 0)
        }
    }

    private func checkRecoveryAccess() throws {
        guard operation == .disableInternal else { return }
        try powerGate.check()
        try authorizationLock.withLock {
            guard lifecycle.permitsRecovery else { throw InternalPowerGateError.suspended }
            let wakeEpoch = activeWakeRecoveryEpoch ?? wakePreflightEpoch
            if let wakeEpoch, !stopping {
                guard lifecycle.sleepEpoch == wakeEpoch else { throw InternalPowerGateError.suspended }
                guard !lifecycle.faulted, !lifecycle.stopRequested,
                      let elapsed = recoveryClock.elapsedNanoseconds(),
                      elapsed < internalWakeRecoveryBudgetNanoseconds else { throw GuardError.suspended }
            }
        }
    }

    private func checkWakePreflightAccess(_ expected: RecoveryRecord, epoch: UUID, consume: Bool = false) throws {
        try powerGate.check()
        try checkProtectedPeer()
        guard try store.load() == expected else { throw RecoveryError.unfinishedTransaction }
        try authorizationLock.withLock {
            guard lifecycle.sleepEpoch == epoch, lifecycle.shouldRecoverAfterWake,
                  lifecycle.resumeAfterWake, !lifecycle.faulted, !lifecycle.stopRequested else {
                throw InternalPowerGateError.suspended
            }
            guard authorization.ready else { throw GuardError.protectionLost }
            // 醒后只读核验既有责任，尚未进入新控制事务。
            try authorization.verifyAcknowledgement(record: expected)
            guard !expected.sourceUnresolved else { throw RecoveryError.unresolvedSource }
            guard let elapsed = recoveryClock.elapsedNanoseconds(),
                  elapsed < internalWakeRecoveryBudgetNanoseconds else { throw GuardError.suspended }
            if consume { wakePreflightEpoch = epoch }
        }
        try powerGate.check()
        try checkProtectedPeer()
        guard try store.load() == expected else { throw RecoveryError.unfinishedTransaction }
    }

    private func readGuardSnapshot(_ record: RecoveryRecord) throws -> Snapshot {
        if operation == .disableInternal { try powerGate.check() }
        let snapshot = try freshGuardSnapshot(responsibility: record.internalDisplay, numericIDHint: internalDisplayIDHint)
        if operation == .disableInternal { try powerGate.check() }
        return snapshot
    }

    private func pausedSnapshot(_ record: RecoveryRecord) throws -> Snapshot {
        try checkProtectedPeer()
        let before = try readGuardSnapshot(record)
        let after = try readGuardSnapshot(record)
        guard clamshellState() == "开盖",
              after.assessment.issues.allSatisfy({ [.noExternalDisplay, .externalNotOnline, .externalNotActive].contains($0) }),
              try store.load() == record else { throw GuardError.suspended }
        guard before == after, after.assessment.isSupported,
              after.displays.count == 2,
              after.displays.allSatisfy({ $0.isActive && $0.isOnline && !$0.isMirrored }) else { throw GuardError.unstable }
        try checkProtectedPeer()
        return after
    }

    @discardableResult
    private func pauseForConfiguration(
        forSleep: Bool,
        attempt: Int = 0
    ) -> Bool {
        guard operation == .disableInternal, !stopping else { return false }
        reapplication.cancel()
        if !forSleep { authorizationLock.withLock { lifecycle.requestPause() } }
        let epoch = authorizationLock.withLock { lifecycle.sleepEpoch }
        let previousWakeRecoveryEpoch = activeWakeRecoveryEpoch
        activeWakeRecoveryEpoch = forSleep && authorizationLock.withLock {
            lifecycle.sleepEpoch == epoch && lifecycle.wakeRecoveryRequired && !lifecycle.sleeping
        } ? epoch : nil
        defer { activeWakeRecoveryEpoch = previousWakeRecoveryEpoch }
        var wakePreflightRecord: RecoveryRecord?
        let shouldPreflightWake = forSleep && authorizationLock.withLock {
            lifecycle.sleepEpoch == epoch && lifecycle.shouldRecoverAfterWake && lifecycle.resumeAfterWake &&
                !lifecycle.faulted && !lifecycle.stopRequested && wakePreflightEpoch != epoch
        }
        var attemptedWakePreflight = false
        var completedWakePreflight = false
        do {
            if shouldPreflightWake {
                attemptedWakePreflight = true
                guard let expected = record else { throw GuardError.missingRecord }
                wakePreflightRecord = expected
                try expected.validate()
                guard let responsibility = expected.internalDisplay, responsibility.baseline,
                      let hardware = responsibility.hardwareIdentity,
                      let id = internalDisplayIDHint ?? responsibility.numericIDHint else { throw GuardError.identity }
                try hardware.validate()
                try checkWakePreflightAccess(expected, epoch: epoch)
                // 先取当前时刻，再读耗时，避免两次采样间隔延长原预算。
                let now = try ContinuousClock.nanoseconds()
                guard let deadline = internalWakeWitnessDeadline(now: now, elapsed: recoveryClock.elapsedNanoseconds()) else {
                    throw GuardError.suspended
                }
                let state = try freshInternalDisplay(
                    identity: responsibility.identity, numericIDHint: id, hardwareIdentity: hardware,
                    deadlineNanoseconds: deadline,
                    checkAccess: { try self.checkWakePreflightAccess(expected, epoch: epoch) }
                )
                guard state.matches(identity: responsibility.identity, hardwareIdentity: hardware) else {
                    throw GuardError.identity
                }
                try checkWakePreflightAccess(expected, epoch: epoch, consume: true)
                internalDisplayIDHint = state.id
                completedWakePreflight = true
            }
            var restored = try InternalSleepPreparation.restore(checkAccess: { try self.checkRecoveryAccess() }, stopObserving: {
                traceInternalLifecycle(.observerDrainStarted)
                stopConnectionObserver()
                traceInternalLifecycle(.observerDrainFinished)
            }, operation: { try restoreRecord() })
            record = restored
            traceInternalLifecycle(.pauseVerificationStarted)
            let snapshot = try pausedSnapshot(restored)
            traceInternalLifecycle(.pauseVerificationFinished)
            guard let responsibility = restored.internalDisplay else { throw GuardError.identity }
            try restored.resumeInternalObservation(
                current: snapshot.layout(),
                internalEnabled: snapshot.builtInDisplay(identity: responsibility.identity).isActive
            )
            guard try store.load() == record else { throw RecoveryError.unfinishedTransaction }
            try store.save(restored)
            record = restored
            try authorizationLock.withLock {
                guard lifecycle.permitsRecovery, lifecycle.sleepEpoch == epoch else { throw InternalPowerGateError.suspended }
                if activeWakeRecoveryEpoch == epoch || wakePreflightEpoch == epoch {
                    guard !lifecycle.faulted, !lifecycle.stopRequested,
                          let elapsed = recoveryClock.elapsedNanoseconds(),
                          elapsed < internalWakeRecoveryBudgetNanoseconds else { throw GuardError.suspended }
                }
                lifecycle.didRestore()
            }
            resetRecoveryCycle()
            if let applicationCallbacks {
                if let expectation = try? InternalApplicationExpectation(record: restored) {
                    applicationCallbacks.expectation(expectation)
                }
                applicationCallbacks.status(.manualConfiguration)
            }
            print("已恢复并暂停；可手动设置 C 后输入 confirm-user，再输入 reapply；输入 stop 恢复退出。保护进程继续等待真实退出。")
            scheduleWakeReapplication()
            return true
        } catch {
            if error as? InternalPowerGateError == .suspended {
                print("恢复等待系统完成唤醒；保护、模式意图及责任继续保留。")
                return false
            }
            let readinessDelay = attemptedWakePreflight && !completedWakePreflight
                ? authorizationLock.withLock {
                    internalWakeInformationRetryDelay(
                        error: error, elapsed: recoveryClock.elapsedNanoseconds(), lifecycle: lifecycle
                    )
                }
                : nil
            if let delay = readinessDelay {
                guard let expected = wakePreflightRecord else {
                    loseProtection()
                    stop()
                    return false
                }
                do {
                    try checkWakePreflightAccess(expected, epoch: epoch)
                } catch let error as InternalPowerGateError where error == .suspended {
                    return false
                } catch {
                    loseProtection()
                    stop()
                    return false
                }
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.stopping,
                          self.powerGate.isReady,
                          self.authorizationLock.withLock({
                              self.lifecycle.sleepEpoch == epoch && self.lifecycle.shouldRecoverAfterWake &&
                                  self.lifecycle.resumeAfterWake && !self.lifecycle.faulted && !self.lifecycle.stopRequested
                          }) else { return }
                    _ = self.pauseForConfiguration(forSleep: true, attempt: attempt)
                }
                return false
            }
            if !attemptedWakePreflight || completedWakePreflight, forSleep,
               let delay = authorizationLock.withLock({
                   internalWakeVerificationRetryDelay(error: error, attempt: attempt, lifecycle: lifecycle)
               }) {
                queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, !self.stopping,
                          self.authorizationLock.withLock({ self.lifecycle.sleepEpoch == epoch && self.lifecycle.shouldRecoverAfterWake }) else { return }
                    _ = self.pauseForConfiguration(forSleep: true, attempt: attempt + 1)
                }
                return false
            }
            traceInternalLifecycle(.restorationFailed, succeeded: false, error: error)
            loseProtection()
            print("暂停前恢复未能核验；保留责任，转入恢复退出。")
            stop()
            return false
        }
    }

    private func confirmUserConfiguration() throws {
        guard operation == .disableInternal, !stopping,
              authorizationLock.withLock({ lifecycle.permitsControls }),
              let current = try store.load(), current == record else { throw GuardError.suspended }
        let snapshot = try pausedSnapshot(current)
        let observed = try confirmProtectedInternalConfiguration(record: current, snapshot: snapshot)
        guard authorizationLock.withLock({ lifecycle.permitsControls }) else { throw GuardError.suspended }
        try store.save(observed)
        record = observed
        stopConnectionObserver()
        authorizationLock.withLock { lifecycle.didConfirmUserConfiguration() }
        print("已确认用户 C；不修改显示设置，后续恢复以 C 为准。")
    }

    private func reapply(stillCurrent: @escaping @Sendable () -> Bool = { true }) throws {
        guard operation == .disableInternal, !stopping, stillCurrent(),
              authorizationLock.withLock({ lifecycle.paused && lifecycle.permitsControls }),
              let current = try store.load(), current == record else { throw GuardError.suspended }
        let snapshot = try pausedSnapshot(current)
        let prepared = try prepareProtectedInternalReapplication(record: current, snapshot: snapshot)
        guard stillCurrent(), let responsibility = current.internalDisplay else { throw GuardError.suspended }
        internalDisplayIDHint = try snapshot.builtInDisplay(identity: responsibility.identity).id
        do {
            try startConnectionObserver(responsibility: responsibility)
            try checkProtectedPeer()
            try authorizationLock.withLock { try lifecycle.beginReapplication(isCurrent: stillCurrent()) }
            resetRecoveryCycle()
            applicationIsCurrent = stillCurrent
            defer { applicationIsCurrent = nil }
            applicationCallbacks?.expectation(try InternalApplicationExpectation(record: prepared))
            try applyPrepared(prepared)
            if !stopping && !authorizationLock.withLock({ lifecycle.paused }) {
                print("重新应用已独立读回；沿用同一保护进程及最新用户 C，输入 restore 或 stop 恢复。")
                applicationCallbacks?.status(.applied)
            }
        } catch {
            if authorizationLock.withLock({ lifecycle.pauseAfterFailure(error, protectionReady: authorization.ready) }) {
                if authorizationLock.withLock({ lifecycle.permitsRecovery }) {
                    pauseForConfiguration(forSleep: true)
                }
            } else {
                loseProtection()
                stop()
            }
            throw error
        }
    }

    private func prepareForSleep() -> Bool {
        let accepted = authorizationLock.withLock {
            guard powerGate.willSleep() else { return false }
            let previousEpoch = lifecycle.sleepEpoch
            guard lifecycle.willSleep() else { return false }
            if lifecycle.sleepEpoch != previousEpoch { wakePreflightEpoch = nil }
            return true
        }
        guard accepted else { return false }
        recoveryClock.willSleep()
        reapplication.invalidate()
        let timestamp = try? ContinuousClock.nanoseconds()
        // 观察排空可能等待在途控制，不能占用电源确认回调。
        queue.async { [weak self] in
            traceInternalLifecycle(.sleepRequested, observedAt: timestamp)
            self?.stopConnectionObserver()
        }
        return true
    }

    private func didPrepareForSleep(accepted: Bool, acknowledged: Bool) {
        guard accepted else { return }
        powerGate.didAcknowledgeSleep(acknowledged)
        authorizationLock.withLock { lifecycle.finishSleepPreparation(acknowledged: acknowledged) }
        if !acknowledged { loseProtection() }
        let timestamp = try? ContinuousClock.nanoseconds()
        queue.async { [weak self] in
            traceInternalLifecycle(.powerAcknowledged, succeeded: acknowledged, observedAt: timestamp)
            self?.recoverAfterWake()
        }
    }

    private func didWake() {
        let timestamp = try? ContinuousClock.nanoseconds()
        guard powerGate.didWake() else { return }
        recoveryClock.didWake()
        recoveryClock.start(at: timestamp)
        let wake = authorizationLock.withLock { () -> (UUID, Bool) in
            lifecycle.didWake()
            return (lifecycle.sleepEpoch, lifecycle.wakeRecoveryRequired && !lifecycle.sleeping &&
                    !lifecycle.faulted && !lifecycle.stopRequested)
        }
        if wake.1 { enforceWakeRecoveryDeadline(epoch: wake.0) }
        queue.async { [weak self] in
            traceInternalLifecycle(.systemHasPoweredOn, observedAt: timestamp)
            self?.recoverAfterWake()
        }
    }

    private func enforceWakeRecoveryDeadline(epoch: UUID) {
        let decision = authorizationLock.withLock {
            let decision = internalWakeRecoveryDeadlineDecision(
                epoch: epoch, lifecycle: &lifecycle, elapsed: recoveryClock.elapsedNanoseconds()
            )
            if decision == .expired { authorization.markLost() }
            return decision
        }
        switch decision {
        case .stale:
            return
        case .wait(let delay):
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.enforceWakeRecoveryDeadline(epoch: epoch)
            }
        case .expired:
            applicationCallbacks?.faulted()
            reapplication.invalidate()
            queue.async { [weak self] in self?.stop() }
        }
    }

    private func recoverAfterWake() {
        guard authorizationLock.withLock({ lifecycle.permitsRecovery }) else { return }
        if stopping || authorizationLock.withLock({ lifecycle.stopRequested || lifecycle.faulted }) {
            stop()
        } else if authorizationLock.withLock({ lifecycle.shouldRecoverAfterWake }) {
            // 只在独立核验 C 并恢复观察后，才允许调度新的停用。
            _ = pauseForConfiguration(forSleep: true)
        }
    }

    private func scheduleWakeReapplication(attempt: Int = 0) {
        guard !stopping, authorizationLock.withLock({ lifecycle.shouldResumeAfterWake && authorization.ready }) else { return }
        reapplication.schedule { [weak self] isCurrent in
            guard let self, isCurrent(),
                  self.authorizationLock.withLock({ self.lifecycle.shouldResumeAfterWake && self.authorization.ready }) else { return }
            withoutActuallyEscaping(isCurrent) { isCurrent in
                do { try self.reapply(stillCurrent: isCurrent) }
                catch {
                    if error as? GuardError == .unstable, attempt < 2 {
                        self.scheduleWakeReapplication(attempt: attempt + 1)
                    } else {
                        print("醒后重新应用未完成；保持恢复责任，不自动采纳新的用户配置。")
                    }
                }
            }
        }
    }

    private func resetRecoveryCycle() {
        authorizationLock.withLock {
            guard !lifecycle.faulted, !lifecycle.stopRequested else { return }
            recoveryEpoch = UUID()
            recoveryRetryScheduled = false
            wakePreflightEpoch = nil
            recoveryClock.reset()
            recoveryFailed = false
        }
    }

    private func restoreRecord() throws -> RecoveryRecord {
        try checkRecoveryAccess()
        guard let record else { throw GuardError.missingRecord }
        let contract = try ProtectionHandshake(
            session: record.session, generation: record.generation, parentPID: getpid(),
            internalDisplayIdentity: record.internalDisplay?.identity,
            internalDisplayHardwareIdentity: record.internalDisplay?.hardwareIdentity
        )
        return try recoverGuardRecord(
            store: store, contract: contract,
            snapshotReader: { try self.readGuardSnapshot(record) },
            internalReader: { identity in
                guard let id = self.internalDisplayIDHint else { throw GuardError.identity }
                return try freshInternalDisplay(identity: identity, numericIDHint: id,
                                                hardwareIdentity: record.internalDisplay?.hardwareIdentity)
            },
            enableInternal: { restoring in
                guard let enableTransaction = self.enableTransaction else { throw GuardError.protectionLost }
                try enableTransaction.enableInternalForRecovery(
                    record: restoring, loadRecord: { try self.store.load() },
                    trace: { traceInternalLifecycle($0, cgError: $1) },
                    nativeCall: { invoke in
                        try self.checkRecoveryAccess()
                        // CGBegin 返回后，setEnabled 才安装 Cancel defer。
                        return try self.powerGate.perform(invoke)
                    },
                    internalReader: { identity in
                        try self.checkRecoveryAccess()
                        try self.powerGate.check()
                        guard let id = self.internalDisplayIDHint else { throw GuardError.identity }
                        let state = try freshInternalDisplay(identity: identity, numericIDHint: id,
                                                             hardwareIdentity: restoring.internalDisplay?.hardwareIdentity)
                        try self.checkRecoveryAccess()
                        return state
                    }
                )
            },
            originWriter: { _, origins in
                guard self.operation == .disableInternal else { throw GuardError.protectionLost }
                // Complete 消费配置句柄；超时由外层下一次访问检查处理，避免 defer 取消已消费句柄。
                try configureOrigins(
                    origins, option: .forSession,
                    nativeCall: { invoke in
                        try self.checkRecoveryAccess()
                        return try self.powerGate.perform(invoke)
                    },
                    validateBeforeCommit: { try self.checkRecoveryAccess() }
                )
            },
            layoutRejected: { traceInternalLifecycle(.layoutRestoreRejected, succeeded: false, recoveryLayout: $0) },
            trace: { traceInternalLifecycle($0) },
            checkAccess: { try self.checkRecoveryAccess() }
        )
    }

    private func stop() {
        reapplication.cancel()
        authorizationLock.withLock { lifecycle.requestStop() }
        stopping = true
        recoveryFailed = false
        if applicationCallbacks != nil, record == nil, child == 0 {
            do {
                if try store.load() == nil {
                    applicationCallbacks?.stopped(authorizationLock.withLock { lifecycle.faulted })
                    exit(EXIT_SUCCESS)
                }
            } catch {
                applicationCallbacks?.status(.quitFailed)
                return
            }
        }
        recoveryClock.start()
        guard operation != .disableInternal || authorizationLock.withLock({ lifecycle.permitsRecovery }) else {
            recoveryFailed = true
            applicationCallbacks?.status(.quitFailed)
            print("退出请求已保留；等待唤醒后恢复，保护与责任继续保留。")
            return
        }
        do {
            let verifiedSleepEpoch = authorizationLock.withLock { lifecycle.sleepEpoch }
            record = try restoreRecord()
            // 恢复不等待诊断；退出前才收束回调，保留触发本轮撤权的记录。
            drainConnectionObservations(afterStoppingProducer: stopConnectionObserver)
            if authorizationLock.withLock({ authorization.ready }) {
                do { try channel?.send(GuardCommand.quiesce) }
                catch {
                    loseProtection()
                    print("辅助进程失效；禁止新控制，已核验的恢复结果仍保留。")
                }
            } else {
                print("保护失效；禁止新控制，恢复结果已核验。")
            }
            print("主进程核验完成；辅助进程将等待主进程退出后独立读回，记录暂不清除。")
            let canExit = authorizationLock.withLock {
                lifecycle.beginExitAfterRecovery(verifiedSleepEpoch: verifiedSleepEpoch) {
                    operation != .disableInternal || powerGate.beginExitAfterRecovery()
                }
            }
            guard canExit else {
                print("退出条件已变化；等待重新核验及电源就绪，保护与记录继续保留。")
                return
            }
            applicationCallbacks?.stopped(authorizationLock.withLock { lifecycle.faulted })
            exit(EXIT_SUCCESS)
        } catch {
            if operation == .disableInternal {
                if error as? InternalPowerGateError == .suspended {
                    recoveryFailed = true
                    applicationCallbacks?.status(.quitFailed)
                    return
                }
                traceInternalLifecycle(.restorationFailed, succeeded: false, error: error)
                loseProtection()
                recoveryFailed = true
                applicationCallbacks?.status(.quitFailed)
                print("恢复未完成；禁止新停用，主进程保留责任。可输入 stop 重试。")
                let elapsed = recoveryClock.elapsedNanoseconds()
                if let delay = internalRecoveryRetryDelay(attemptCount: 1, elapsed: elapsed) {
                    scheduleRecoveryRetry(after: delay)
                } else {
                    print("恢复未能在计时窗口内核验；保留责任与保护，等待显示事件或 stop，不作为时限通过。")
                }
                return
            }
            print("演练核验未完成；保留责任，辅助进程继续等待退出。")
            exit(EXIT_FAILURE)
        }
    }
    private func scheduleRecoveryRetry(after delay: Double) {
        guard !recoveryRetryScheduled, operation != .disableInternal || authorizationLock.withLock({ lifecycle.permitsRecovery }) else { return }
        recoveryRetryScheduled = true
        let epoch = recoveryEpoch
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.recoveryEpoch == epoch else { return }
            self.recoveryRetryScheduled = false
            guard self.recoveryFailed, self.operation != .disableInternal || self.authorizationLock.withLock({ self.lifecycle.permitsRecovery }) else { return }
            self.stop()
        }
    }
}

final class DisplayGuard: @unchecked Sendable {
    private let channel: GuardChannel
    private let store: RecoveryStore
    private let contract: ProtectionHandshake
    private let readinessRecord: RecoveryRecord
    private let enableTransaction: DisplayEnableTransaction?
    private var internalDisplayIDHint: UInt32?
    private let queue = DispatchQueue(label: "Extilume.display-guard")
    private var parentSource: DispatchSourceProcess?
    private var inputSource: DispatchSourceRead?
    private var parentExited = false
    private var attemptCount = 0
    private var lastFailureStage: String?
    private var notificationAt: UInt64?
    private var displayCallbackRegistered = false
    private var retryScheduled = false
    private let powerGate = InternalPowerGate()
    private var powerObserver: InternalSystemPowerObserver?
    private let recoveryClock = InternalRecoveryClock()

    init(directory: URL, descriptor: Int32) throws {
        channel = try GuardChannel(descriptor: descriptor)
        contract = try channel.receive(ProtectionHandshake.self)
        guard getppid() == contract.parentPID, kill(contract.parentPID, 0) == 0 else { throw GuardError.identity }
        store = try RecoveryStore(directory: directory)
        guard let record = try store.load(), contract.accepts(record: record),
              record.phase == .applying, !record.sourceUnresolved else { throw GuardError.missingRecord }
        readinessRecord = record
        internalDisplayIDHint = record.internalDisplay?.numericIDHint
        enableTransaction = record.internalDisplay == nil ? nil : try DisplayEnableTransaction()
        if let responsibility = record.internalDisplay {
            if let boot = responsibility.hardwareIdentity?.bootSession { recoveryClock.setBootSession(boot) }
            guard responsibility.baseline else { throw GuardError.missingRecord }
            let observer = InternalSystemPowerObserver(
                prepareForSleep: { [weak self] in
                    guard let self, self.powerGate.willSleep() else { return false }
                    self.recoveryClock.willSleep()
                    return true
                },
                didPrepareForSleep: { [weak self] accepted, acknowledged in
                    guard let self, accepted else { return }
                    self.powerGate.didAcknowledgeSleep(acknowledged)
                    self.queue.async { [weak self] in
                        guard let self, self.parentExited else { return }
                        self.attemptRecovery()
                    }
                },
                didWake: { [weak self] in
                    guard let self, self.powerGate.didWake() else { return }
                    self.recoveryClock.didWake()
                    let timestamp = try? ContinuousClock.nanoseconds()
                    self.queue.async { [weak self] in
                        traceInternalLifecycle(.systemHasPoweredOn, role: .helper, observedAt: timestamp)
                        guard let self, self.parentExited else { return }
                        self.attemptRecovery()
                    }
                },
                onFailure: { [weak self] in self?.powerGate.invalidate() }
            )
            try observer.start()
            powerObserver = observer
            powerGate.didRegister()
            try powerGate.check()
            let snapshot = try freshGuardSnapshot(responsibility: record.internalDisplay, numericIDHint: internalDisplayIDHint, diagnosticRole: .helper)
            let builtIn = try snapshot.builtInDisplay(identity: responsibility.identity)
            internalDisplayIDHint = builtIn.id
            let independent = try freshInternalDisplay(identity: responsibility.identity, numericIDHint: builtIn.id,
                                                      hardwareIdentity: responsibility.hardwareIdentity, diagnosticRole: .helper)
            try powerGate.check()
            try validateInternalGuardReadiness(
                snapshot: snapshot, record: record, internalState: independent,
                lidOpen: clamshellState() == "开盖"
            )
        } else {
            guard record.baseline == record.applied else { throw GuardError.missingRecord }
        }
    }

    func start() throws {
        try queue.sync {
        if contract.internalDisplayIdentity != nil {
            guard CGDisplayRegisterReconfigurationCallback(
                guardDisplayCallback, Unmanaged.passUnretained(self).toOpaque()
            ) == .success else { throw GuardError.protectionLost }
            displayCallbackRegistered = true
        }
        let source = DispatchSource.makeProcessSource(identifier: contract.parentPID, eventMask: .exit, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self, !self.parentExited else { return }
            self.parentExited = true
            self.notificationAt = try? ContinuousClock.nanoseconds()
            self.recoveryClock.start()
            self.inputSource?.cancel()
            self.attemptRecovery()
        }
        parentSource = source
        source.resume()
        let input = DispatchSource.makeReadSource(fileDescriptor: channel.descriptor, queue: queue)
        input.setEventHandler { [weak self] in
            guard let self, !self.parentExited else { return }
            do {
                if try self.channel.peerClosed() {
                    self.inputSource?.cancel()
                    return // EOF 不代替父进程退出；父进程仍可能持锁并正在恢复。
                }
                let command = try self.channel.receive(GuardCommand.self)
                if command == .quiesce {
                    print("辅助进程收到停止接管通知；继续保护到主进程实际退出。")
                    self.inputSource?.cancel()
                }
            } catch { self.inputSource?.cancel() }
        }
        inputSource = input
        input.resume()
        guard getppid() == contract.parentPID, kill(contract.parentPID, 0) == 0, try !channel.peerClosed() else {
            throw GuardError.identity
        }
        guard try store.load() == readinessRecord else { throw GuardError.missingRecord }
        if contract.internalDisplayIdentity != nil { try powerGate.check() }
        try channel.send(GuardReply(ready: contract, powerReady: contract.internalDisplayIdentity == nil ? nil : true))
        }
    }

    deinit {
        powerObserver?.stop()
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(guardDisplayCallback, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    fileprivate func displayChanged() {
        queue.async { [weak self] in
            guard let self, self.parentExited, self.attemptCount > 0 else { return }
            self.scheduleRecovery(after: 0)
        }
    }

    private func scheduleRecovery(after delay: Double) {
        guard !retryScheduled, contract.internalDisplayIdentity == nil || powerGate.isReady else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.attemptRecovery()
        }
    }

    private func attemptRecovery() {
        guard contract.internalDisplayIdentity == nil || powerGate.isReady else { return }
        var stage = "取得独占锁"
        do {
            try store.acquireExclusiveOwnership()
            stage = "读取责任记录"
            guard let record = try store.load() else { throw GuardError.missingRecord }
            stage = "检查归属与责任范围"
            // 不同会话不属于旧握手；保留新责任并释放锁，而非替它恢复。
            guard record.session == contract.session else {
                print("责任记录属于其他会话；旧辅助进程未执行恢复，保留记录并退出。")
                exit(EXIT_SUCCESS)
            }
            stage = "独立恢复与终验"
            var independentlyVerified = try recoverGuardRecord(
                store: store, contract: contract,
                snapshotReader: { try freshGuardSnapshot(responsibility: record.internalDisplay, numericIDHint: self.internalDisplayIDHint, diagnosticRole: .helper) },
                internalReader: { [self] identity in
                    guard let internalDisplayIDHint else { throw GuardError.identity }
                    return try freshInternalDisplay(identity: identity, numericIDHint: internalDisplayIDHint,
                                                    hardwareIdentity: record.internalDisplay?.hardwareIdentity, diagnosticRole: .helper)
                },
                enableInternal: { [self] record in
                    guard let enableTransaction else { throw GuardError.protectionLost }
                    try enableTransaction.enableInternalForRecovery(
                        record: record, loadRecord: { try self.store.load() },
                        trace: { traceInternalLifecycle($0, role: .helper, cgError: $1) },
                        nativeCall: { try self.powerGate.perform($0) },
                        internalReader: { [self] identity in
                            try powerGate.check()
                            guard let internalDisplayIDHint else { throw GuardError.identity }
                            return try freshInternalDisplay(identity: identity, numericIDHint: internalDisplayIDHint,
                                                            hardwareIdentity: record.internalDisplay?.hardwareIdentity, diagnosticRole: .helper)
                        }
                    )
                },
                originWriter: { restoring, origins in
                    guard let responsibility = restoring.internalDisplay,
                          responsibility.pending, !responsibility.applied else { throw GuardError.protectionLost }
                    try configureOrigins(origins, option: .forSession, nativeCall: { try self.powerGate.perform($0) })
                },
                layoutRejected: { traceInternalLifecycle(.layoutRestoreRejected, role: .helper, succeeded: false, recoveryLayout: $0) },
                trace: { traceInternalLifecycle($0, role: .helper) },
                checkAccess: {
                    if self.contract.internalDisplayIdentity != nil { try self.powerGate.check() }
                }
            )
            stage = "读取完成计时"
            let elapsed = try ContinuousClock.nanoseconds() - (notificationAt ?? 0)
            if contract.internalDisplayIdentity != nil {
                guard parentExited, try store.load() == independentlyVerified else { throw GuardError.protectionLost }
                try independentlyVerified.confirmIndependentGuardVerification()
                try store.save(independentlyVerified)
            }
            if contract.internalDisplayIdentity != nil, !powerGate.beginExitAfterRecovery() { return }
            print("辅助进程在主进程退出后独立读取并核验完成；通知至核验=\(elapsed / 1_000_000) ms。该值不代表实际故障至恢复时限。")
            exit(EXIT_SUCCESS)
        } catch {
            if error as? InternalPowerGateError == .suspended { return }
            attemptCount += 1
            traceInternalLifecycle(.restorationFailed, role: .helper, succeeded: false, error: error)
            if lastFailureStage != stage {
                print("辅助进程尚未核验恢复；失败阶段=\(stage)，保留责任，不提前退出。")
                lastFailureStage = stage
            }
            let elapsed = recoveryClock.elapsedNanoseconds()
            if contract.internalDisplayIdentity != nil {
                if let delay = internalRecoveryRetryDelay(attemptCount: attemptCount, elapsed: elapsed) {
                    scheduleRecovery(after: delay)
                } else {
                    print("恢复未能在计时窗口内核验；责任与保护继续保留，等待显示事件，不作为时限通过。")
                }
            } else {
                scheduleRecovery(after: min(30.0, 0.1 * pow(2.0, Double(min(attemptCount, 9)))))
            }
        }
    }
}

private func guardSessionDisplayCallback(
    _ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<GuardSession>.fromOpaque(context).takeUnretainedValue().displayChangedForRecovery()
}

private func guardDisplayCallback(
    _ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<DisplayGuard>.fromOpaque(context).takeUnretainedValue().displayChanged()
}
