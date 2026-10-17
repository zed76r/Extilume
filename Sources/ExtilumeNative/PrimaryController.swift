import AppKit
import CoreGraphics
import Darwin
import ExtilumeCore
import Foundation

private enum PrimaryError: Error {
    case unsupported, unstable, transactionFailed, readbackMismatch, superseded
}

extension Snapshot {
    func layout() throws -> DisplayLayout {
        let active = displays.filter(\.isActive)
        guard let main = active.first(where: \.isMain)?.identityUUID,
              active.allSatisfy({ $0.identityUUID != nil && $0.isOnline && !$0.isMirrored }),
              Set(active.compactMap(\.identityUUID)).count == active.count else { throw PrimaryError.unsupported }
        var origins: [UUID: DisplayOrigin] = [:]
        for display in active {
            guard let identity = display.identityUUID,
                  let x = Int32(exactly: display.originX),
                  let y = Int32(exactly: display.originY) else { throw PrimaryError.unsupported }
            origins[identity] = DisplayOrigin(x: x, y: y)
        }
        return try DisplayLayout(main: main, origins: origins)
    }

    func connected() throws -> [ConnectedDisplay] {
        try displays.filter(\.isActive).map {
            guard let identity = $0.identityUUID else { throw PrimaryError.unsupported }
            return ConnectedDisplay(identity: identity, numericID: $0.id)
        }
    }
}

func stableSnapshot(activeOnly: Bool = false) throws -> Snapshot {
    var before = try readSnapshot(activeOnly: activeOnly)
    for _ in 0..<20 {
        Thread.sleep(forTimeInterval: 0.1)
        let after = try readSnapshot(activeOnly: activeOnly)
        if before == after { return after }
        before = after
    }
    throw PrimaryError.unstable
}

func configureOrigins(_ origins: [UInt32: DisplayOrigin], option: CGConfigureOption,
                      validateBeforeCommit: () throws -> Void = {}) throws {
    guard !origins.isEmpty else { return }
    try validateBeforeCommit()
    var configuration: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
        throw PrimaryError.transactionFailed
    }
    var completed = false
    defer { if !completed { CGCancelDisplayConfiguration(configuration) } }
    for (id, origin) in origins.sorted(by: { $0.key < $1.key }) {
        guard CGConfigureDisplayOrigin(configuration, id, origin.x, origin.y) == .success else {
            throw PrimaryError.transactionFailed
        }
    }
    try validateBeforeCommit()
    let completion = CGCompleteDisplayConfiguration(configuration, option)
    completed = true // SDK 规定 Complete 返回后句柄无效，包括失败返回。
    guard completion == .success else {
        throw PrimaryError.transactionFailed
    }
}

// 所有状态仅由 queue 访问；系统回调与输入线程只负责入队。
final class PrimaryController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Extilume.primary")
    private let store: RecoveryStore
    private var record: RecoveryRecord?
    private var wakeObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var signals: [DispatchSourceSignal] = []
    private var registered = false
    private var stopping = false
    private var transactions = 0
    private let reapplication: PrimaryReapplicationScheduler
    private let snapshotReader: @Sendable () throws -> Snapshot
    private let originWriter: @Sendable ([UInt32: DisplayOrigin], CGConfigureOption) throws -> Void
    private let lidReader: @Sendable () -> String
    private var statusHandler: (@Sendable (PrimarySessionStatus) -> Void)?
    private var applicationStatus: PrimarySessionStatus = .waiting
    private var priorResponsibility = false
    private var applicationWantsEvents = false
    private var applicationResumePending = false
    private let applicationRequestLock = NSLock()
    private var applicationRequestIdentifier: UUID?
    private var activeApplicationRequestIdentifier: UUID?
    private var quitRequested = false
    private var applicationSleepRequested = false
    private var configurationEpoch = UUID()

    private var applicationIsSleeping: Bool {
        applicationRequestLock.withLock { applicationSleepRequested }
    }

    init(
        directory: URL,
        snapshotReader: @escaping @Sendable () throws -> Snapshot = { try freshSnapshot() },
        originWriter: @escaping @Sendable ([UInt32: DisplayOrigin], CGConfigureOption) throws -> Void = { try configureOrigins($0, option: $1) },
        lidReader: @escaping @Sendable () -> String = { clamshellState() }
    ) throws {
        self.snapshotReader = snapshotReader
        self.originWriter = originWriter
        self.lidReader = lidReader
        reapplication = PrimaryReapplicationScheduler(ownerQueue: queue)
        store = try RecoveryStore(directory: directory)
        try store.acquireExclusiveOwnership()
    }

    func recoverOnly() throws {
        try queue.sync {
            record = try store.load()
            guard record?.phase != .restored else { throw RecoveryError.unfinishedTransaction }
            if var pending = record, pending.sourceUnresolved {
                // 原进程已退出；完整基准的独立读回只解除责任，不生成补偿写入。
                guard pending.internalDisplay == nil,
                      try snapshotReader().layout() == pending.baseline,
                      try snapshotReader().layout() == pending.baseline else {
                    throw RecoveryError.unresolvedSource
                }
                pending.beginRestoration()
                try store.save(pending)
                try pending.confirmRestored(actual: pending.baseline)
                try store.save(pending)
                record = pending
                print("两个独立读回均为完整恢复基准；未写显示配置，记录保留待终验。")
                return
            }
            try restore()
        }
    }

    func confirmUserOnly() throws {
        try queue.sync {
            guard let pending = try store.load(), pending.phase == .owned else {
                throw RecoveryError.unfinishedTransaction
            }
            record = pending
            let snapshot = try snapshotReader()
            guard try snapshot.layout() != pending.applied else { throw RecoveryError.unresolvedSource }
            try observe(source: .confirmedUser)
            guard record?.sourceUnresolved == false, record?.layoutPending == false else {
                throw RecoveryError.unresolvedSource
            }
            print("已按操作人员明确确认的 C 更新恢复基准；本命令未写入显示配置。")
        }
    }

    func finalizeOnly() throws {
        try queue.sync {
            guard let restored = try store.load(), restored.canClear, restored.internalDisplay == nil,
                  try snapshotReader().layout() == restored.baseline else { throw RecoveryError.unfinishedTransaction }
            try store.clear()
            print("独立进程已读回恢复基准；本次责任记录已清除。")
        }
    }

    func start() throws {
        try queue.sync {
            guard try store.load() == nil else { throw RecoveryError.unfinishedTransaction }
            guard CGDisplayRegisterReconfigurationCallback(primaryDisplayCallback,
                Unmanaged.passUnretained(self).toOpaque()) == .success else { throw PrimaryError.unsupported }
            registered = true
            do { try apply() } catch {
                CGDisplayRemoveReconfigurationCallback(primaryDisplayCallback, Unmanaged.passUnretained(self).toOpaque())
                registered = false
                throw error
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.systemDidWake() }
        queue.sync {
            for number in [SIGINT, SIGTERM] {
                signal(number, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
                source.setEventHandler { [weak self] in self?.stop() }
                signals.append(source)
                source.resume()
            }
            print("主屏验证已启动；事务数=\(transactions)。输入 status / confirm-user / reapply / stop。")
        }
        DispatchQueue.global().async { [weak self] in
            while let command = readLine() { self?.command(command.trimmingCharacters(in: .whitespaces)) }
            self?.command("stop")
        }
    }

    func displayChanged(_ flags: CGDisplayChangeSummaryFlags) {
        applicationRequestLock.withLock { configurationEpoch = UUID() }
        let disconnected = !flags.intersection([.removeFlag, .disabledFlag]).isEmpty
        let connected = !flags.intersection([.addFlag, .enabledFlag]).isEmpty
        if flags != .desktopShapeChangedFlag { reapplication.invalidate() }
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            let lid = self.statusHandler == nil ? nil : self.lidReader()
            let sleeping = self.statusHandler != nil && self.applicationIsSleeping
            if sleeping { self.applicationResumePending = true }
            if lid == "合盖", !self.applicationResumePending {
                self.applicationResumePending = true
                print("观察到合盖；暂停新控制，保留原恢复责任。")
            }
            if flags.contains(.beginConfigurationFlag) {
                self.reapplication.cancel()
                return
            }
            if self.statusHandler != nil, self.applicationStatus.needsRecovery, !self.priorResponsibility {
                self.reapplication.cancel()
                return
            }
            if self.applicationResumePending, !sleeping, lid == "开盖" {
                do {
                    let snapshot = try self.snapshotReader()
                    if (try? snapshot.layout()) != nil {
                        try self.observe(source: .reconnect, snapshot: snapshot)
                    }
                } catch { self.publish(.unconfirmed); return }
                self.scheduleReapplication()
                return
            }
            if !sleeping, lid != "合盖", !disconnected && (connected || (flags == .desktopShapeChangedFlag && self.reapplication.hasPending)) {
                self.scheduleReapplication()
                return
            }
            // 用户设置或断开事件不能留下稍后覆盖 C 的旧接管意图。
            self.reapplication.cancel()
            do {
                try self.observe(source: disconnected || lid == "合盖" || sleeping ? .reconnect : .unknown)
                if self.statusHandler != nil { try self.refreshApplicationStatus() }
            } catch {
                print("显示事件来源或拓扑未确认；保留责任，停止本次接管。")
                if self.statusHandler != nil { self.publish(.unconfirmed) }
            }
        }
    }

    func systemWillSleep() {
        applicationRequestLock.withLock {
            applicationSleepRequested = true
            configurationEpoch = UUID()
        }
        reapplication.invalidate()
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            self.applicationResumePending = true
            self.reapplication.cancel()
            print("观察到系统将睡眠；暂停新控制，保留原恢复责任。")
            if !self.applicationStatus.needsRecovery {
                self.publish(.unsupported("系统睡眠中，等待唤醒"))
            }
        }
    }

    func systemDidWake() {
        applicationRequestLock.withLock { configurationEpoch = UUID() }
        reapplication.invalidate()
        queue.async { [weak self] in
            guard let self else { return }
            self.applicationRequestLock.withLock { self.applicationSleepRequested = false }
            guard !self.stopping else { return }
            if self.statusHandler != nil { print("观察到系统唤醒；等待完整开盖双屏稳定。") }
            if self.statusHandler != nil, !self.applicationStatus.canRetryApplication && self.applicationStatus.needsRecovery { return }
            self.scheduleReapplication()
        }
    }

    private func scheduleReapplication() {
        reapplication.schedule { [weak self] isCurrent in
            guard let self, !self.stopping, isCurrent() else { return }
            if self.statusHandler != nil {
                guard !self.applicationIsSleeping else { return }
                if self.applicationResumePending {
                    guard self.lidReader() == "开盖" else {
                        self.publish(.unsupported("需要开盖及内屏扩展桌面"))
                        return
                    }
                    do {
                        let snapshot = try self.snapshotReader()
                        guard snapshot.assessment.isSupported,
                              snapshot.displays.filter(\.isActive).count == 2,
                              snapshot.displays.contains(where: { $0.identity == .builtIn && $0.isActive }) else {
                            try self.refreshApplicationStatus()
                            return
                        }
                    } catch { self.publish(.unconfirmed); return }
                    self.applicationResumePending = false
                    print("生命周期恢复后的双屏已稳定；只核对原基准和原目标。")
                }
                if self.priorResponsibility {
                    do {
                        try self.reconcilePreviousApplication()
                        self.publish(.waiting)
                    } catch { self.publish(.recoveryIncomplete); return }
                }
                self.performApplication(isCurrent: isCurrent)
                return
            }
            do {
                try self.observe(source: .reconnect)
                guard isCurrent() else { return }
                try self.apply(isCurrent: isCurrent)
            }
            catch { print("连接或唤醒后未满足接管条件；保留责任，停止本次接管。") }
        }
    }

    private func command(_ command: String) {
        if ["confirm-user", "reapply", "stop"].contains(command) { reapplication.invalidate() }
        queue.async { [weak self] in
            guard let self, !self.stopping else { return }
            do {
                switch command {
                case "status":
                    let snapshot = try snapshotReader()
                    print("活动屏=\(snapshot.displays.filter(\.isActive).count)；HDMI 主屏=\(snapshot.displays.contains { $0.identity == .physical && $0.isMain })；事务数=\(self.transactions)；未决来源=\(self.record?.sourceUnresolved ?? false)。")
                case "confirm-user":
                    self.reapplication.cancel()
                    try self.observe(source: .confirmedUser)
                    print("已按操作人员的明确用户修改证据记录 C；尚未重新接管。")
                case "reapply": self.reapplication.cancel(); try self.apply()
                case "stop": self.stop()
                default: print("有效命令：status / confirm-user / reapply / stop。")
                }
            } catch { print("操作未完成；保留责任，不继续接管。") }
        }
    }

    private func observe(source: ConfigurationSource, snapshot: Snapshot? = nil) throws {
        guard var record else { return }
        let snapshot = try snapshot ?? snapshotReader()
        let layout = try snapshot.layout()
        if source == .confirmedUser {
            guard record.phase == .owned, layout != record.applied else { throw RecoveryError.unresolvedSource }
        }
        do { try record.observe(layout, source: source) }
        catch { self.record = record; try store.save(record); throw error }
        self.record = record
        try store.save(record)
    }

    func startApplication(registerEvents: Bool = true, recoveryOnly: Bool = false, onStatus: @escaping @Sendable (PrimarySessionStatus) -> Void) {
        queue.async { [self] in
            statusHandler = onStatus
            applicationWantsEvents = registerEvents
            applicationResumePending = lidReader() == "合盖"
            priorResponsibility = true
            do {
                try ensureApplicationEvents()
                try reconcilePreviousApplication()
                if recoveryOnly { publish(.applicationFailedRestored) }
                else { performApplication() }
            } catch {
                publish(.recoveryIncomplete)
            }
        }
        if registerEvents {
            sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.systemWillSleep() }
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
            ) { [weak self] _ in self?.systemDidWake() }
        }
    }

    func retryApplication() {
        guard let request = beginApplicationRequest() else { return }
        queue.async { [self] in
            activeApplicationRequestIdentifier = request
            defer { activeApplicationRequestIdentifier = nil; endApplicationRequest(request) }
            guard !stopping, applicationStatus.canRetryApplication else { return }
            reapplication.cancel()
            do {
                try ensureApplicationEvents()
                performApplication()
            } catch { publish(.recoveryIncomplete) }
        }
    }

    func recoverApplication() {
        guard let request = beginApplicationRequest() else { return }
        reapplication.invalidate()
        queue.async { [self] in
            activeApplicationRequestIdentifier = request
            defer { activeApplicationRequestIdentifier = nil; endApplicationRequest(request) }
            guard applicationStatus.needsRecovery else { return }
            reapplication.cancel()
            do {
                try ensureApplicationEvents()
                if priorResponsibility { try reconcilePreviousApplication() }
                else { try restore(allowKnownBaseline: true) }
                publish(.applicationFailedRestored)
            } catch {
                if stopping { publish(quitRecoveryFailureStatus()) }
                else if !priorResponsibility, record?.phase == .owned, record?.sourceUnresolved == true {
                    publish(.unconfirmed)
                } else { publish(.recoveryIncomplete) }
            }
        }
    }

    func confirmCurrentConfiguration() {
        let epoch = applicationRequestLock.withLock { configurationEpoch }
        guard let request = beginApplicationRequest() else { return }
        reapplication.invalidate()
        queue.async { [self] in
            activeApplicationRequestIdentifier = request
            defer { activeApplicationRequestIdentifier = nil; endApplicationRequest(request) }
            reapplication.cancel()
            guard applicationStatus.canConfirmConfiguration, !priorResponsibility,
                  let original = record, original.phase == .owned,
                  original.internalDisplay == nil, original.sourceUnresolved else {
                publish(.confirmationFailed)
                return
            }
            do {
                let snapshot = try snapshotReader()
                let layout = try snapshot.layout()
                guard lidReader() == "开盖", snapshot.assessment.isSupported,
                      snapshot.displays.filter(\.isActive).count == 2,
                      snapshot.displays.contains(where: { $0.identity == .builtIn && $0.isActive }),
                      Set(layout.origins.keys) == Set(original.baseline.origins.keys),
                      layout != original.applied,
                      try snapshotReader() == snapshot else { throw PrimaryError.unstable }
                guard applicationRequestLock.withLock({ configurationEpoch == epoch && !applicationSleepRequested }) else {
                    throw PrimaryError.superseded
                }
                var candidate = original
                try candidate.observe(layout, source: .confirmedUser)
                guard candidate.baseline == layout, !candidate.sourceUnresolved, !candidate.layoutPending,
                      try snapshotReader() == snapshot,
                      lidReader() == "开盖" else { throw PrimaryError.unstable }
                try applicationRequestLock.withLock {
                    guard configurationEpoch == epoch, !applicationSleepRequested else { throw PrimaryError.superseded }
                    // 最后核对后一次提交；提交后的事件按新变化处理，不回滚已确认的 C。
                    try store.save(candidate)
                    record = candidate
                }
                endApplicationRequest(request)
                publish(.manualConfiguration)
            } catch {
                record = original
                publish((try? store.load()) == original ? .confirmationFailed : .recoveryIncomplete)
            }
        }
    }

    func quitApplication(completion: @escaping @Sendable (Bool) -> Void) {
        applicationRequestLock.withLock {
            quitRequested = true
            configurationEpoch = UUID()
        }
        reapplication.invalidate()
        queue.async { [self] in
            stopping = true
            reapplication.cancel()
            publish(.restoringAndQuitting)
            do {
                if priorResponsibility { try reconcilePreviousApplication() }
                else { try restore(allowKnownBaseline: true) }
                if registered {
                    CGDisplayRemoveReconfigurationCallback(primaryDisplayCallback, Unmanaged.passUnretained(self).toOpaque())
                    registered = false
                }
                if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
                wakeObserver = nil
                if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
                sleepObserver = nil
                completion(true)
            } catch {
                publish(quitRecoveryFailureStatus())
                completion(false)
            }
        }
    }

    private func ensureApplicationEvents() throws {
        guard applicationWantsEvents, !registered else { return }
        guard CGDisplayRegisterReconfigurationCallback(primaryDisplayCallback,
            Unmanaged.passUnretained(self).toOpaque()) == .success else { throw PrimaryError.unsupported }
        registered = true
    }

    private func beginApplicationRequest() -> UUID? {
        applicationRequestLock.withLock {
            guard applicationRequestIdentifier == nil else { return nil }
            let identifier = UUID()
            applicationRequestIdentifier = identifier
            return identifier
        }
    }

    private func endApplicationRequest(_ identifier: UUID) {
        applicationRequestLock.withLock {
            if applicationRequestIdentifier == identifier { applicationRequestIdentifier = nil }
        }
    }

    private func publish(_ status: PrimarySessionStatus) {
        applicationStatus = status
        if status.canRetryApplication || status.needsRecovery, let request = activeApplicationRequestIdentifier {
            // 先释放本轮请求，再通知界面允许重试；旧请求的 defer 不能清除新请求。
            endApplicationRequest(request)
        }
        statusHandler?(status)
    }

    private func quitRecoveryFailureStatus() -> PrimarySessionStatus {
        if let record, let current = try? snapshotReader().layout(),
           !Set(record.baseline.origins.keys).isSubset(of: Set(current.origins.keys)) {
            return .quitWaitingForDisplays
        }
        return .quitFailed
    }

    private func reconcilePreviousApplication() throws {
        record = try store.load()
        guard var pending = record else { priorResponsibility = false; return }
        if pending.sourceUnresolved {
            guard pending.internalDisplay == nil,
                  try snapshotReader().layout() == pending.baseline,
                  try snapshotReader().layout() == pending.baseline else { throw RecoveryError.unresolvedSource }
            pending.beginRestoration()
            try pending.confirmRestored(actual: pending.baseline)
            try store.save(pending)
            record = pending
        } else if !pending.canClear { try restore() }
        guard let restored = record, restored.canClear, restored.internalDisplay == nil,
              try snapshotReader().layout() == restored.baseline else { throw RecoveryError.unfinishedTransaction }
        try store.clear()
        record = nil
        priorResponsibility = false
    }

    private func performApplication(isCurrent: @Sendable () -> Bool = { true }) {
        guard !stopping, !priorResponsibility, !applicationStatus.needsRecovery else { return }
        if applicationIsSleeping {
            publish(.unsupported("系统睡眠中，等待唤醒"))
            return
        }
        do {
            try observe(source: .reconnect)
            guard isCurrent(), !applicationRequestLock.withLock({ quitRequested || applicationSleepRequested }) else { return }
            publish(.applying)
            try apply(isCurrent: isCurrent)
            try refreshApplicationStatus()
        } catch {
            if record?.sourceUnresolved == true { publish(.unconfirmed); return }
            if applicationIsSleeping {
                publish(.unsupported("系统睡眠中，等待唤醒"))
                return
            }
            do {
                try restore()
                publish(.applicationFailedRestored)
            } catch { publish(.recoveryIncomplete) }
        }
    }

    private func refreshApplicationStatus() throws {
        if stopping { return }
        if record?.sourceUnresolved == true { publish(.unconfirmed); return }
        if applicationIsSleeping { publish(.unsupported("系统睡眠中，等待唤醒")); return }
        if let record, record.phase != .owned && record.phase != .restored {
            publish(.recoveryIncomplete)
            return
        }
        if applicationStatus == .applicationFailedRestored { return }
        let snapshot = try snapshotReader()
        if snapshot.assessment.issues == [.noExternalDisplay] { publish(.waiting); return }
        guard snapshot.assessment.isSupported else {
            publish(.unsupported(snapshot.assessment.issues.map(issueDescription).joined(separator: "；")))
            return
        }
        guard lidReader() == "开盖", snapshot.displays.filter(\.isActive).count == 2,
              snapshot.displays.contains(where: { $0.identity == .builtIn && $0.isActive }) else {
            publish(.unsupported("需要开盖及内屏扩展桌面"))
            return
        }
        publish(snapshot.displays.contains(where: { $0.identity == .physical && $0.isMain }) ? .applied : .manualConfiguration)
    }

    private func apply(isCurrent: @Sendable () -> Bool = { true }) throws {
        let snapshot = try snapshotReader()
        guard isCurrent(), !(statusHandler != nil && applicationRequestLock.withLock({ quitRequested || applicationSleepRequested })) else { throw PrimaryError.superseded }
        guard lidReader() == "开盖", snapshot.assessment.isSupported,
              snapshot.displays.filter({ $0.identity == .builtIn && $0.isActive }).count == 1,
              snapshot.displays.filter(\.isActive).count == 2,
              let targetID = snapshot.displays.first(where: { $0.identity == .physical })?.identityUUID else {
            print("等待开盖、物理 HDMI 与稳定双屏非镜像桌面；未执行新控制，已有责任保留。")
            return
        }
        let current = try snapshot.layout()
        let target = try layoutByMakingMain(current, target: targetID)
        if let record, record.sourceUnresolved { throw RecoveryError.unresolvedSource }
        // 重复的连接及自身事件在 B 上不产生新的事务。
        guard target != current else { return }
        let prepared: RecoveryRecord
        if let restored = record, restored.canClear {
            guard current == restored.baseline else { throw RecoveryError.unresolvedSource }
            prepared = try RecoveryRecord(baseline: restored.baseline, target: target)
        } else if var existing = record {
            try existing.prepareReapplication(current: current, target: target)
            prepared = existing
        } else {
            prepared = try RecoveryRecord(baseline: current, target: target)
        }
        let mapping = try snapshot.connected()
        var origins: [UInt32: DisplayOrigin] = [:]
        for display in mapping { origins[display.numericID] = target.origins[display.identity] }
        var stage = "责任记录落盘"
        do {
            record = try store.apply(prepared, beforeOperation: {
                stage = "写入前独立读回"
                let immediatelyBefore = try snapshotReader()
                guard isCurrent(), lidReader() == "开盖",
                      !(statusHandler != nil && applicationRequestLock.withLock({ quitRequested || applicationSleepRequested })) else { throw PrimaryError.superseded }
                guard immediatelyBefore == snapshot else { throw PrimaryError.unstable }
            }) {
                stage = "公开坐标写入"
                try originWriter(origins, .forAppOnly)
                stage = "写入后目标读回"
                let after = try snapshotReader().layout()
                guard after == target else { throw PrimaryError.readbackMismatch }
                stage = "应用确认与记录落盘"
                return (after, nil)
            }
            transactions += 1
            print("公开坐标事务已读回；事务数=\(transactions)。内屏仍须现场确认扩展桌面。")
        } catch {
            print("主屏事务未完成；失败阶段=\(stage)，责任记录保留。")
            record = try store.load()
            throw error
        }
    }

    private func restore(allowKnownBaseline: Bool = false) throws {
        guard var record else { print("没有本次待恢复记录。"); return }
        guard record.internalDisplay == nil else { throw RecoveryError.unfinishedTransaction }
        let snapshot = try snapshotReader()
        let current = try snapshot.layout()
        // C 后直接退出也须提交当前 C，避免 forAppOnly 的退出回退覆盖它。
        let origins: [UInt32: DisplayOrigin]
        if allowKnownBaseline, record.sourceUnresolved {
            guard current == record.baseline else { throw RecoveryError.unresolvedSource }
            let connected = try snapshot.connected()
            guard Set(connected.map(\.numericID)).count == connected.count,
                  connected.allSatisfy({ $0.numericID != 0 }) else { throw RecoveryError.identityConflict }
            // 仅显式恢复完整旧基准；不把当前未知布局认作新 C。
            origins = Dictionary(uniqueKeysWithValues: connected.map { ($0.numericID, current.origins[$0.identity]!) })
        } else {
            let plan = try record.layoutRestorePlan(connected: snapshot.connected(), current: current)
            if record.baseline == record.applied, current == record.baseline {
                origins = [:] // 不改配置的保护演练只读回，不生成补偿事务。
            } else if !record.layoutPending {
                origins = Dictionary(uniqueKeysWithValues: try snapshot.connected().map { ($0.numericID, current.origins[$0.identity]!) })
            } else { origins = plan.origins }
        }
        record.beginRestoration()
        self.record = record
        try store.save(record)
        guard try snapshotReader() == snapshot else { throw PrimaryError.unstable }
        guard !(statusHandler != nil && applicationIsSleeping) else { throw PrimaryError.superseded }
        try originWriter(origins, .forSession)
        let after = try snapshotReader().layout()
        do { try record.confirmRestored(actual: after) }
        catch { self.record = record; try store.save(record); throw error }
        // 退出后独立观测才有权清除记录；进程内读回不能证明作用域退出结果。
        self.record = record
        try store.save(record)
        print("恢复提交与进程内读回完成；退出后须独立核对 C，责任记录保留。")
    }

    private func stop() {
        stopping = true
        reapplication.cancel()
        var success = true
        do { try restore() } catch { success = false; print("恢复未完成；保留未决责任。") }
        if registered { CGDisplayRemoveReconfigurationCallback(primaryDisplayCallback, Unmanaged.passUnretained(self).toOpaque()) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        signals.forEach { $0.cancel() }
        exit(success ? EXIT_SUCCESS : EXIT_FAILURE)
    }
}

private func primaryDisplayCallback(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<PrimaryController>.fromOpaque(context).takeUnretainedValue().displayChanged(flags)
}
