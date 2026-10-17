import AppKit
import CoreGraphics
import Darwin
import ExtilumeCore
import Foundation

private struct GuardReply: Codable { let ready: ProtectionHandshake }
private enum GuardCommand: String, Codable { case quiesce }
private enum GuardError: Error, Equatable { case spawn, identity, missingRecord, protectionLost, suspended, unstable }

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
    private var stopping = false
    private var internalDisplayIDHint: UInt32?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var recoveryFailed = false
    private var recoveryStartedAt: UInt64?
    private var recoveryRetryScheduled = false
    private var recoveryEpoch = UUID()

    init(directory: URL, operation: GuardSessionOperation) throws {
        self.directory = directory
        self.operation = operation
        enableTransaction = operation == .disableInternal ? try DisplayEnableTransaction() : nil
        store = try RecoveryStore(directory: directory)
        reapplication = PrimaryReapplicationScheduler(ownerQueue: queue)
        try store.acquireExclusiveOwnership()
        queue.setSpecific(key: queueKey, value: true)
    }

    deinit {
        for observer in [sleepObserver, wakeObserver].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        connectionObserver?.stopObserving()
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
                try startConnectionObserver(responsibility: internalResponsibility)
            }
            if operation == .disableInternal {
                sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
                ) { [weak self] _ in self?.willSleep() }
                wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                    forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
                ) { [weak self] _ in self?.didWake() }
            }
            let prepared = try RecoveryRecord(baseline: baseline, target: baseline, internalDisplay: internalResponsibility)
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
            }
        }
        DispatchQueue.global().async { [weak self] in
            while let command = readLine() {
                self?.command(command.trimmingCharacters(in: .whitespaces))
            }
            self?.command("stop")
        }
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
        if child == 0 {
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
            try translateProtectedInternalLayout(
                record: durable, loadRecord: { try self.store.load() },
                snapshotReader: { try self.readGuardSnapshot(durable) },
                originWriter: { origins, validate in
                    try configureOrigins(origins, option: .forAppOnly, validateBeforeCommit: validate)
                },
                checkProtection: { try self.checkProtection($0) }
            )
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

    private func command(_ command: String) {
        if ["restore", "stop"].contains(command) {
            reapplication.invalidate()
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
            case "stop": self.stop()
            case "restore" where self.operation == .disableInternal:
                self.pauseForConfiguration(forSleep: false)
            case "confirm-user" where self.operation == .disableInternal:
                self.reapplication.cancel()
                do { try self.confirmUserConfiguration() }
                catch { print("用户配置未获确认；原基准及恢复责任保留。") }
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
        try checkProtectedPeer()
        try authorizationLock.withLock {
            guard authorization.ready && !lifecycle.faulted else { throw GuardError.protectionLost }
            guard !lifecycle.pauseRequested else { throw InternalControlCancellation.pauseRequested }
            guard lifecycle.permitsControls else { throw GuardError.suspended }
            try authorization.authorize(record: record)
        }
        guard applicationIsCurrent?() != false else { throw GuardError.suspended }
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
        authorizationLock.withLock {
            authorization.markLost()
            lifecycle.fail()
        }
    }

    private func connectionInvalidated(message: String = "连接安全条件失效；禁止新控制，主进程负责核验恢复。", observerEpoch: UUID? = nil) {
        // 危险事件立即撤权，不等待控制队列上的快照或握手。
        let invalidated = authorizationLock.withLock {
            if let observerEpoch, connectionObserverEpoch != observerEpoch { return false }
            authorization.markLost()
            lifecycle.fail()
            return true
        }
        guard invalidated else { return }
        reapplication.invalidate()
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            self.stop()
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
            onReconfiguration: { [weak self] in
                self?.queue.async { [weak self] in
                    guard let self, self.recoveryFailed,
                          self.authorizationLock.withLock({ self.connectionObserverEpoch == epoch }) else { return }
                    self.scheduleRecoveryRetry(after: 0)
                }
            }
        ) { [weak self] reason in
            self?.connectionInvalidated(
                message: "连接安全条件失效 [\(reason)]；禁止新控制，主进程负责核验恢复。", observerEpoch: epoch
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

    private func readGuardSnapshot(_ record: RecoveryRecord) throws -> Snapshot {
        try freshGuardSnapshot(responsibility: record.internalDisplay, numericIDHint: internalDisplayIDHint)
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
    private func pauseForConfiguration(forSleep: Bool) -> Bool {
        guard operation == .disableInternal, !stopping else { return false }
        reapplication.cancel()
        if !forSleep { authorizationLock.withLock { lifecycle.requestPause() } }
        do {
            var restored = try restoreRecord()
            record = restored
            stopConnectionObserver()
            let snapshot = try pausedSnapshot(restored)
            guard let responsibility = restored.internalDisplay else { throw GuardError.identity }
            try restored.resumeInternalObservation(
                current: snapshot.layout(),
                internalEnabled: snapshot.builtInDisplay(identity: responsibility.identity).isActive
            )
            guard try store.load() == record else { throw RecoveryError.unfinishedTransaction }
            try store.save(restored)
            record = restored
            authorizationLock.withLock { lifecycle.didRestore() }
            resetRecoveryCycle()
            print("已恢复并暂停；可手动设置 C 后输入 confirm-user，再输入 reapply；输入 stop 恢复退出。保护进程继续等待真实退出。")
            scheduleWakeReapplication()
            return true
        } catch {
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
            guard stillCurrent() else { throw GuardError.suspended }
            try authorizationLock.withLock { try lifecycle.beginReapplication() }
            resetRecoveryCycle()
            applicationIsCurrent = stillCurrent
            defer { applicationIsCurrent = nil }
            try applyPrepared(prepared)
            if !stopping && !authorizationLock.withLock({ lifecycle.paused }) {
                print("重新应用已独立读回；沿用同一保护进程及最新用户 C，输入 restore 或 stop 恢复。")
            }
        } catch {
            loseProtection()
            stop()
            throw error
        }
    }

    private func willSleep() {
        let deadline = DispatchTime.now() + .seconds(10)
        reapplication.invalidate()
        authorizationLock.withLock { lifecycle.willSleep() }
        let restored = InternalSleepPreparation.wait(
            on: queue, alreadyOnQueue: DispatchQueue.getSpecific(key: queueKey) != nil,
            deadline: deadline
        ) { [weak self] in self?.pauseForConfiguration(forSleep: true) ?? false }
        authorizationLock.withLock { lifecycle.finishSleepPreparation(restored: restored) }
        if !restored {
            loseProtection()
            print("睡前恢复未能在同步等待期限内核验；禁止新停用，保留恢复责任。")
        }
        queue.async { [weak self] in
            guard let self else { return }
            if restored { self.scheduleWakeReapplication() }
            else { self.stop() }
        }
    }

    private func didWake() {
        authorizationLock.withLock { lifecycle.didWake() }
        queue.async { [weak self] in
            guard let self else { return }
            if self.recoveryFailed { self.scheduleRecoveryRetry(after: 0) }
            else { self.scheduleWakeReapplication() }
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
        recoveryEpoch = UUID()
        recoveryRetryScheduled = false
        recoveryStartedAt = nil
        recoveryFailed = false
    }

    private func restoreRecord() throws -> RecoveryRecord {
        guard let record else { throw GuardError.missingRecord }
        let contract = try ProtectionHandshake(
            session: record.session, generation: record.generation, parentPID: getpid(),
            internalDisplayIdentity: record.internalDisplay?.identity,
            internalDisplayHardwareIdentity: record.internalDisplay?.hardwareIdentity
        )
        return try recoverGuardRecord(
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
    }

    private func stop() {
        reapplication.cancel()
        authorizationLock.withLock { lifecycle.requestPause() }
        stopping = true
        recoveryFailed = false
        if recoveryStartedAt == nil { recoveryStartedAt = try? ContinuousClock.nanoseconds() }
        do {
            record = try restoreRecord()
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
            exit(EXIT_SUCCESS)
        } catch {
            if operation == .disableInternal {
                loseProtection()
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
        let epoch = recoveryEpoch
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.recoveryEpoch == epoch else { return }
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
