import AppKit
import CoreGraphics
import Darwin
import ExtilumeCore
import Foundation

private struct GuardReply: Codable { let ready: ProtectionHandshake }
private enum GuardCommand: String, Codable { case quiesce }
private enum GuardError: Error { case spawn, identity, missingRecord, protectionLost }

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
    private var record: RecoveryRecord?
    private var channel: GuardChannel?
    private var child: pid_t = 0
    private var deathSource: DispatchSourceProcess?
    private var protectionInputSource: DispatchSourceRead?
    private var signals: [DispatchSourceSignal] = []
    private let authorizationLock = NSLock()
    private var authorization = ProtectionAuthorization()
    private var connectionObserver: ConnectionObserver?
    private var stopping = false
    private var internalDisplayIDHint: UInt32?
    private var sleepObserver: NSObjectProtocol?
    private var recoveryFailed = false
    private var recoveryStartedAt: UInt64?
    private var recoveryRetryScheduled = false

    init(directory: URL, operation: GuardSessionOperation) throws {
        self.directory = directory
        self.operation = operation
        enableTransaction = operation == .disableInternal ? try DisplayEnableTransaction() : nil
        store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
    }

    func start() throws {
        try queue.sync {
            guard try store.load() == nil else { throw RecoveryError.unfinishedTransaction }
            let snapshot = try freshSnapshot()
            let baseline = try snapshot.layout()
            let internalResponsibility: InternalDisplayResponsibility?
            if operation != .drill {
                guard clamshellState() == "开盖", snapshot.assessment.isSupported,
                      let builtIn = snapshot.displays.first(where: { $0.identity == .builtIn }),
                      let identity = builtIn.identityUUID, builtIn.isActive && builtIn.isOnline,
                      snapshot.displays.contains(where: { $0.identity == .physical && $0.isMain }) else {
                    throw GuardError.protectionLost
                }
                let independent = try freshInternalDisplay(identity: identity, numericIDHint: builtIn.id)
                guard independent.id == builtIn.id, independent.isEnabled,
                      let hardware = independent.hardwareIdentity else { throw GuardError.identity }
                internalDisplayIDHint = builtIn.id
                internalResponsibility = InternalDisplayResponsibility(
                    identity: identity, baseline: true, applied: operation != .disableInternal,
                    hardwareIdentity: hardware, numericIDHint: builtIn.id
                )
            } else {
                internalResponsibility = nil
            }
            if snapshot.assessment.isSupported {
                let observer = try ConnectionObserver(
                    service: matchedHDMIService(), reportsEvents: false,
                    expectedDisabledInternal: operation == .disableInternal ? internalDisplayIDHint : nil,
                    expectedInternalRegistryID: operation == .disableInternal ? internalResponsibility?.hardwareIdentity?.registryEntryID : nil,
                    onReconfiguration: { [weak self] in
                        self?.queue.async { [weak self] in
                            guard let self, self.recoveryFailed else { return }
                            self.scheduleRecoveryRetry(after: 0)
                        }
                    }
                ) { [weak self] reason in
                    self?.connectionInvalidated(message: "连接安全条件失效 [\(reason)]；禁止新控制，主进程负责核验恢复。")
                }
                connectionObserver = observer
                try observer.start()
            }
            if operation == .disableInternal {
                sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
                ) { [weak self] _ in self?.connectionInvalidated() }
            }
            let prepared = try RecoveryRecord(baseline: baseline, target: baseline, internalDisplay: internalResponsibility)
            do {
                let apply: (RecoveryRecord) throws -> (layout: DisplayLayout, internalEnabled: Bool?) = { [self] durable in
                    let contract = try ProtectionHandshake(
                        session: durable.session, generation: durable.generation, parentPID: getpid(),
                        internalDisplayIdentity: durable.internalDisplay?.identity,
                        internalDisplayHardwareIdentity: durable.internalDisplay?.hardwareIdentity
                    )
                    let parentChannel: GuardChannel = try {
                        let pair = try GuardChannel.pair()
                        child = try spawnProbe(["--display-guard", directory.path], channel: pair.1)
                        return pair.0
                    }()
                    channel = parentChannel
                    let source = DispatchSource.makeProcessSource(identifier: child, eventMask: .exit, queue: .global())
                    source.setEventHandler { [weak self] in
                        guard let self else { return }
                        self.authorizationLock.withLock { self.authorization.markLost() }
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
                    try authorizationLock.withLock { try authorization.acknowledge(receipt: reply.ready, expected: contract) }
                    let input = DispatchSource.makeReadSource(fileDescriptor: parentChannel.descriptor, queue: .global())
                    input.setEventHandler { [weak self] in
                        self?.protectionInputSource?.cancel()
                        self?.connectionInvalidated(message: "保护通信失效；禁止新控制，主进程负责核验恢复。")
                    }
                    protectionInputSource = input
                    input.resume()
                    guard try !parentChannel.peerClosed(), kill(child, 0) == 0 else {
                        authorizationLock.withLock { authorization.markLost() }
                        throw GuardError.protectionLost
                    }
                    try checkProtection(durable)
                    if let enableTransaction {
                        return try performProtectedInternalDisable(
                            record: durable, loadRecord: { try self.store.load() },
                            disable: { pending in
                                try enableTransaction.disableInternal(
                                    record: pending, loadRecord: { try self.store.load() },
                                    snapshotReader: { try freshSnapshot() }, lidIsOpen: { clamshellState() == "开盖" },
                                    checkProtection: { try self.checkProtection($0) },
                                    internalReader: { identity in
                                        guard let id = self.internalDisplayIDHint else { throw GuardError.identity }
                                        return try freshInternalDisplay(identity: identity, numericIDHint: id,
                                                                        hardwareIdentity: pending.internalDisplay?.hardwareIdentity)
                                    }
                                )
                            },
                            activeSnapshotReader: { try freshActiveSnapshot() },
                            internalReader: { identity in
                                guard let internalDisplayIDHint else { throw GuardError.identity }
                                return try freshInternalDisplay(identity: identity, numericIDHint: internalDisplayIDHint,
                                                                hardwareIdentity: durable.internalDisplay?.hardwareIdentity)
                            },
                            checkProtection: { try self.checkProtection($0) }
                        )
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
                if operation == .disableInternal {
                    if let applied = try applyProtectedInternalRecord(
                        store: store, prepared: prepared, operation: apply,
                        recoverOnFailure: { [self] durable in
                            record = durable
                            authorizationLock.withLock { authorization.markLost() }
                            print("停用事务未完成；主进程接管恢复，不依赖辅助进程仍存活。")
                            stop()
                        }
                    ) { record = applied }
                } else {
                    record = try store.apply(prepared) {
                        guard let durable = try store.load() else { throw GuardError.missingRecord }
                        return try apply(durable)
                    }
                }
            } catch {
                record = try store.load()
                // 子进程已启动时须随主进程退出继续核验，不能杀掉保护来掩盖握手失败。
                throw error
            }
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
                    print("受保护停用已读回；尚需现场确认桌面、键盘及触控板。输入 status / stop 恢复退出。")
                } else {
                    print("不改显示设置的保护演练已就绪；连接观察=\(connectionObserver != nil)；输入 status / stop / crash / lose-guard / invalidate-connection。")
                }
            }
        }
        DispatchQueue.global().async { [weak self] in
            while let command = readLine() {
                self?.command(command.trimmingCharacters(in: .whitespaces))
            }
            self?.command("stop")
        }
    }

    private func command(_ command: String) {
        if command == "invalidate-connection" {
            print("模拟连接安全条件失效；不代表实际拔线。")
            connectionInvalidated()
            return
        }
        queue.async { [weak self] in
            guard let self, !self.stopping || self.recoveryFailed else { return }
            switch command {
            case "status":
                let ready = self.authorizationLock.withLock { self.authorization.ready }
                print("主进程仍在运行；保护就绪=\(ready)；连接观察=\(self.connectionObserver != nil)；责任尚未独立清除。")
            case "stop": self.stop()
            case "crash": _exit(99)
            case "lose-guard": _ = kill(self.child, SIGKILL)
            default: print("有效命令：status / stop / crash / lose-guard / invalidate-connection。")
            }
        }
    }

    private func checkProtection(_ record: RecoveryRecord) throws {
        guard let channel, try !channel.peerClosed(), kill(child, 0) == 0 else {
            authorizationLock.withLock { authorization.markLost() }
            throw GuardError.protectionLost
        }
        try authorizationLock.withLock { try authorization.authorize(record: record) }
    }

    private func connectionInvalidated(message: String = "连接安全条件失效；禁止新控制，主进程负责核验恢复。") {
        // 危险事件立即撤权，不等待控制队列上的快照或握手。
        authorizationLock.withLock { authorization.markLost() }
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            self.stop()
        }
        print(message)
    }

    private func stop() {
        stopping = true
        recoveryFailed = false
        if recoveryStartedAt == nil { recoveryStartedAt = try? ContinuousClock.nanoseconds() }
        do {
            guard let record else { throw GuardError.missingRecord }
            let contract = try ProtectionHandshake(
                session: record.session, generation: record.generation, parentPID: getpid(),
                internalDisplayIdentity: record.internalDisplay?.identity,
                internalDisplayHardwareIdentity: record.internalDisplay?.hardwareIdentity
            )
            _ = try recoverGuardRecord(
                store: store, contract: contract,
                snapshotReader: { try freshGuardSnapshot(responsibility: record.internalDisplay, numericIDHint: self.internalDisplayIDHint) },
                internalReader: { identity in
                    guard let id = self.internalDisplayIDHint else { throw GuardError.identity }
                    return try freshInternalDisplay(identity: identity, numericIDHint: id,
                                                    hardwareIdentity: record.internalDisplay?.hardwareIdentity)
                },
                enableInternal: { restoring in
                    guard let enableTransaction = self.enableTransaction else { throw GuardError.protectionLost }
                    try enableTransaction.enableInternalForRecovery(
                        record: restoring, loadRecord: { try self.store.load() },
                        internalReader: { identity in
                            guard let id = self.internalDisplayIDHint else { throw GuardError.identity }
                            return try freshInternalDisplay(identity: identity, numericIDHint: id,
                                                            hardwareIdentity: restoring.internalDisplay?.hardwareIdentity)
                        }
                    )
                },
                originWriter: { origins in
                    guard self.operation == .disableInternal else { throw GuardError.protectionLost }
                    try configureOrigins(origins, option: .forSession)
                }
            )
            if authorizationLock.withLock({ authorization.ready }) {
                do { try channel?.send(GuardCommand.quiesce) }
                catch {
                    authorizationLock.withLock { authorization.markLost() }
                    print("辅助进程失效；禁止新控制，已核验的恢复结果仍保留。")
                }
            } else {
                print("保护失效；禁止新控制，恢复结果已核验。")
            }
            print("主进程核验完成；辅助进程将等待主进程退出后独立读回，记录暂不清除。")
            exit(EXIT_SUCCESS)
        } catch {
            if operation == .disableInternal {
                authorizationLock.withLock { authorization.markLost() }
                recoveryFailed = true
                print("恢复未完成；禁止新停用，主进程保留责任。可输入 stop 重试。")
                let elapsed = (try? ContinuousClock.nanoseconds()).flatMap { now in
                    recoveryStartedAt.flatMap { now >= $0 ? now - $0 : nil }
                }
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
        guard !recoveryRetryScheduled else { return }
        recoveryRetryScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.recoveryRetryScheduled = false
            guard self.recoveryFailed else { return }
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
    private let internalDisplayIDHint: UInt32?
    private let queue = DispatchQueue(label: "Extilume.display-guard")
    private var parentSource: DispatchSourceProcess?
    private var inputSource: DispatchSourceRead?
    private var parentExited = false
    private var attemptCount = 0
    private var lastFailureStage: String?
    private var notificationAt: UInt64?
    private var displayCallbackRegistered = false
    private var retryScheduled = false

    init(directory: URL, descriptor: Int32) throws {
        channel = try GuardChannel(descriptor: descriptor)
        contract = try channel.receive(ProtectionHandshake.self)
        guard getppid() == contract.parentPID, kill(contract.parentPID, 0) == 0 else { throw GuardError.identity }
        store = try RecoveryStore(directory: directory)
        guard let record = try store.load(), contract.accepts(record: record),
              record.phase == .applying, !record.sourceUnresolved else { throw GuardError.missingRecord }
        if let responsibility = record.internalDisplay {
            guard responsibility.baseline else { throw GuardError.missingRecord }
            enableTransaction = try DisplayEnableTransaction()
            let snapshot = try freshGuardSnapshot(responsibility: record.internalDisplay, numericIDHint: nil)
            let builtIn = try snapshot.builtInDisplay(identity: responsibility.identity)
            internalDisplayIDHint = builtIn.id
            let independent = try freshInternalDisplay(identity: responsibility.identity, numericIDHint: builtIn.id,
                                                      hardwareIdentity: responsibility.hardwareIdentity)
            guard snapshot.assessment.isSupported, clamshellState() == "开盖",
                  builtIn.isActive && builtIn.isOnline, try snapshot.layout() == record.applied,
                  independent.isEnabled, independent.id == builtIn.id,
                  snapshot.displays.contains(where: { $0.identity == .physical && $0.isMain }) else {
                throw GuardError.protectionLost
            }
        } else {
            guard record.baseline == record.applied else { throw GuardError.missingRecord }
            enableTransaction = nil
            internalDisplayIDHint = nil
        }
        readinessRecord = record
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
        try channel.send(GuardReply(ready: contract))
        }
    }

    deinit {
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
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            self.attemptRecovery()
        }
    }

    private func attemptRecovery() {
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
            _ = try recoverGuardRecord(
                store: store, contract: contract,
                snapshotReader: { try freshGuardSnapshot(responsibility: record.internalDisplay, numericIDHint: self.internalDisplayIDHint) },
                internalReader: { [self] identity in
                    guard let internalDisplayIDHint else { throw GuardError.identity }
                    return try freshInternalDisplay(identity: identity, numericIDHint: internalDisplayIDHint,
                                                    hardwareIdentity: record.internalDisplay?.hardwareIdentity)
                },
                enableInternal: { [self] record in
                    guard let enableTransaction else { throw GuardError.protectionLost }
                    try enableTransaction.enableInternalForRecovery(
                        record: record, loadRecord: { try self.store.load() },
                        internalReader: { [self] identity in
                            guard let internalDisplayIDHint else { throw GuardError.identity }
                            return try freshInternalDisplay(identity: identity, numericIDHint: internalDisplayIDHint,
                                                            hardwareIdentity: record.internalDisplay?.hardwareIdentity)
                        }
                    )
                },
                originWriter: { origins in
                    guard let responsibility = record.internalDisplay,
                          responsibility.pending, !responsibility.applied else { throw GuardError.protectionLost }
                    try configureOrigins(origins, option: .forSession)
                }
            )
            stage = "读取完成计时"
            let elapsed = try ContinuousClock.nanoseconds() - (notificationAt ?? 0)
            print("辅助进程在主进程退出后独立读取并核验完成；通知至核验=\(elapsed / 1_000_000) ms。该值不代表实际故障至恢复时限。")
            exit(EXIT_SUCCESS)
        } catch {
            attemptCount += 1
            if lastFailureStage != stage {
                print("辅助进程尚未核验恢复；失败阶段=\(stage)，保留责任，不提前退出。")
                lastFailureStage = stage
            }
            let elapsed = (try? ContinuousClock.nanoseconds()).flatMap { now in
                notificationAt.flatMap { now >= $0 ? now - $0 : nil }
            }
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

private func guardDisplayCallback(
    _ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    Unmanaged<DisplayGuard>.fromOpaque(context).takeUnretainedValue().displayChanged()
}
